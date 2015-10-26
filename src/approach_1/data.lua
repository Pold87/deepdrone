require 'torch'
require 'nn'
require 'image'
require 'math'
require 'csvigo'


-- parse command line arguments
if not opt then
   print '==> processing options'
   cmd = torch.CmdLine()
   cmd:text()
   cmd:text('Drone Dataset Preprocessing')
   cmd:text()
   cmd:text('Options:')
   cmd:option('-size', 'small', 'how many samples do we load: small | full | extra')
   cmd:option('-visualize', true, 'visualize input data and weights during training')
   cmd:option('-dof', 1, 'degrees of freedom; 1: only x coordinates, 2: x, y; etc.')
   cmd:text()
   opt = cmd:parse(arg or {})
end


-- Settings
src = image.load("../../data/dice.jpg")
img_folder = "../../../draug/genimgs/"
use_opencl = false
max_iterations = 50

-- Amount of synthetic views

----------------------------------------------------------------------
-- training/test size

if opt.size == 'full' then
   print '==> using regular, full training data'
   trsize = 200 -- training images
   tesize = 100 -- test images
elseif opt.size == 'small' then
   print '==> using reduced training data, for fast experiments'
   trsize = 30
   tesize = 10
end

img_width = 224 / 2
img_height = 224 / 2

x_range = img_width * 2
y_range = img_height * 2
total_range = 300

-- Read CSV and convert to tensor
csv_file = csvigo.load("../../../draug/targets.csv")
target_x = torch.Tensor(csv_file.x)
target_y = torch.Tensor(csv_file.y)
target_z = torch.Tensor(csv_file.z)


-- Start by predicting the x coordinate
trainset = {
   data = torch.Tensor(trsize, 3, img_width, img_height),
   label = torch.FloatTensor(trsize, opt.dof, total_range),
   size = function() return trsize end
}

-- Start by predicting the x coordinate
testset = {
   data = torch.Tensor(tesize, 3, img_width, img_height),
   label = torch.FloatTensor(tesize, opt.dof, total_range),
   size = function() return tesize end
}

function normalized_to_raw(pred, mean_target, stdv_target)
    
    val = pred:clone()
    val = val:cmul(stdv_target)
    val = val:add(mean_target)
    
    return val 
end


function raw_to_normalized(pred, mean_target, stdv_target)
    
    val = pred:clone()
    val = val:add(- mean_target)
    val = val:cdiv(stdv_target)
    
    return val 
end


function sleep(n)
  os.execute("sleep " .. tonumber(n))
end


function makeTargets(y, stdv)
   -- y : (batch_size, num_keypoints*2)
   -- Y : (batch_size, num_keypoints*2, 98)
   Y = torch.FloatTensor(y:size(1), y:size(2), total_range):zero()
   pixels = torch.range(1,total_range):float()
   local k = 0
   for i=1,y:size(1) do
      local keypoints = y[i]
      local new_keypoints = Y[i]
      for j=1,y:size(2) do
         local kp = keypoints[j]
         if kp ~= -1 then
            local new_kp = new_keypoints[j]
            new_kp:add(pixels, -kp)
            new_kp:cmul(new_kp)
            new_kp:div(2 * stdv * stdv)
            new_kp:mul(-1)
            new_kp:exp(new_kp)
            new_kp:div(math.sqrt(2 * math.pi) * stdv)
         else
            k = k + 1
         end
      end
   end
   return Y
end

function makeTargets1D(y, stdv)
   -- y : (batch_size, num_keypoints*2)
   -- Y : (batch_size, num_keypoints*2, 98)
   
   Y = torch.FloatTensor(total_range):zero()
   pixels = torch.range(1,total_range):float()
   local k = 0
   local new_keypoints = Y
   for j=1, Y:size(1) do
         local new_kp = new_keypoints[j]
         new_kp = pixels - y
         new_kp = new_kp * new_kp
         new_kp = new_kp / (2 * stdv * stdv)
         new_kp = - new_kp
         new_kp = math.exp(new_kp)
         new_kp = new_kp / (math.sqrt(2 * math.pi) * stdv)
   end
   return Y
end


function makeTargets1DNew(y, stdv)

end

-- Load train data (incl. Gaussian normalization)
function load_data(dataset, start_pic_num, pics)

   if opt.dof == 1 then
      label = torch.Tensor(pics)
   else
      label = torch.Tensor(pics, opt.dof)
   end

   i_prime = start_pic_num

   for i = 1, pics do

      img = image.load(img_folder .. (i_prime - 1) .. ".png")

      img = image.scale(img, img_width, img_height)
   
      true_x = target_x[i_prime]
      true_x = true_x + 112
      int_true_x = math.min(math.floor(true_x),  total_range)
      

      true_y = target_y[i_prime]
      true_y = true_y + 112
      int_true_y = math.min(math.floor(true_y),  total_range)
      
      dataset.data[i] = img

      -- Degrees of freedom
      if opt.dof == 1 then
         label[i] = true_x
         print(true_x)
      else
         label[i][1] = true_x
      end
      if opt.dof >= 2 then
         label[i][2] = true_y
      end

      i_prime = i_prime + 1

      if opt.dof == 1 then
         dataset.label[i] = makeTargets1D(label, 1)
         print(dataset.label[i])
      end
      
   end

--      if opt.dof ~= 1 then
--         dataset.label = makeTargets(label, 1)
--      end 

end

load_data(trainset, 1, trsize)
load_data(testset, 201, tesize)


function trainset:size() 
    return self.data:size(1) 
end

setmetatable(trainset, 
    {__index = function(t, i) 
                    return {t.data[i], t.label[i]} 
                end}
);


function testset:size() 
    return self.data:size(1) 
end

setmetatable(testset, 
    {__index = function(t, i) 
                    return {t.data[i], t.label[i]} 
                end}
);


----------------------------------------------------------------------
print '==> preprocessing data'

trainset.data = trainset.data:float() -- convert the data from a ByteTensor to a DoubleTensor.
testset.data = testset.data:float() -- convert the data from a ByteTensor to a DoubleTensor.


-- Convert all images to YUV

print '==> preprocessing data: colorspace RGB -> YUV'
for i = 1, trainset:size() do
   trainset.data[i] = image.rgb2yuv(trainset.data[i])
end

for i = 1, testset:size() do
   testset.data[i] = image.rgb2yuv(testset.data[i])
end

-- Name channels for convenience
channels = {'y','u','v'}

-- Normalize each channel, and store mean/std
-- per channel. These values are important, as they are part of
-- the trainable parameters. At test time, test data will be normalized
-- using these values.

print '==> preprocessing data: normalize each feature (channel) globally'
mean = {}
std = {}
for i, channel in ipairs(channels) do
   -- normalize each channel globally:
   mean[i] = trainset.data[{ {},i,{},{} }]:mean()
   std[i] = trainset.data[{ {},i,{},{} }]:std()
   trainset.data[{ {},i,{},{} }]:add(-mean[i])
   trainset.data[{ {},i,{},{} }]:div(std[i])
end

-- Normalize test data, using the training means/stds
for i, channel in ipairs(channels) do
   -- normalize each channel globally:
   testset.data[{ {},i,{},{} }]:add(-mean[i])
   testset.data[{ {},i,{},{} }]:div(std[i])
end

-- Local normalization
print '==> preprocessing data: normalize all three channels locally'

-- Define the normalization neighborhood:
neighborhood = image.gaussian1D(13)

-- Define our local normalization operator (It is an actual nn module, 
-- which could be inserted into a trainable model):
normalization = nn.SpatialContrastiveNormalization(1, neighborhood, 1):float()

-- Normalize all channels locally:
for c in ipairs(channels) do
   for i = 1, trainset:size() do
      trainset.data[{ i,{c},{},{} }] = normalization:forward(trainset.data[{ i,{c},{},{} }])
   end
   for i = 1, testset:size() do
      testset.data[{ i,{c},{},{} }] = normalization:forward(testset.data[{ i,{c},{},{} }])
   end
end


----------------------------------------------------------------------
print '==> verify statistics'

for i, channel in ipairs(channels) do
   trainMean = trainset.data[{ {},i }]:mean()
   trainStd = trainset.data[{ {},i }]:std()

   testMean = testset.data[{ {},i }]:mean()
   testStd = testset.data[{ {},i }]:std()

   print('training data, '..channel..'-channel, mean: ' .. trainMean)
   print('training data, '..channel..'-channel, standard deviation: ' .. trainStd)

   print('test data, '..channel..'-channel, mean: ' .. testMean)
   print('test data, '..channel..'-channel, standard deviation: ' .. testStd)
end

print '==> visualizing data'

if opt.visualize then
   first256Samples_y = trainset.data[{ {1,3},1 }]
   first256Samples_u = trainset.data[{ {1,3},2 }]
   first256Samples_v = trainset.data[{ {1,3},3 }]
--   image.display(first256Samples_y)
--   image.display(first256Samples_u)
--   image.display(first256Samples_v)
   if itorch then
      first256Samples_y = trainData.data[{ {1,256},1 }]
      first256Samples_u = trainData.data[{ {1,256},2 }]
      first256Samples_v = trainData.data[{ {1,256},3 }]
      itorch.image(first256Samples_y)
      itorch.image(first256Samples_u)
      itorch.image(first256Samples_v)
   end
end