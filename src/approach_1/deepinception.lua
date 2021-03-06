require 'dp'

--[[command line arguments]]--
cmd = torch.CmdLine()
cmd:text()
cmd:text('Image Classification using Inception Modules Training/Optimization')
cmd:text('Example:')
cmd:text('$> th examples/deepinception.lua --accUpdate --progress --cuda --batchSize 64 --hiddenSize "{4000,4000,4000}" --lecunlcn --dropout')
cmd:text('Options:')
-- fundamentals 
cmd:option('-learningRate', 0.1, 'learning rate at t=0')
cmd:option('-activation', 'ReLU', 'transfer function like ReLU, Tanh, Sigmoid')
cmd:option('-batchSize', 32, 'number of examples per batch')
cmd:option('-dontPad', false, 'dont add math.floor(kernelSize/2) padding to the input of each convolution') 
-- regularization (and dropout or batchNorm)
cmd:option('-maxOutNorm', 1, 'max norm each layers output neuron weights')
cmd:option('-batchNorm', true, 'use batch normalization. dropout is mostly redundant with this')
cmd:option('-dropout', false, 'use dropout')
cmd:option('-dropoutProb', '{0.2,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5}', 'dropout probabilities')
-- data and preprocessing
cmd:option('-standardize', false, 'apply Standardize preprocessing')
cmd:option('-zca', false, 'apply Zero-Component Analysis whitening')
cmd:option('-lecunlcn', false, 'apply Yann LeCun Local Contrast Normalization (recommended)')
-- convolution layers (before Inception layers, 2 or 3 should do)
cmd:option('-convChannelSize', '{64,128}', 'Number of output channels (number of filters) for each convolution layer.')
cmd:option('-convKernelSize', '{5,5}', 'kernel size of each convolution layer. Height = Width')
cmd:option('-convKernelStride', '{1,1}', 'kernel stride of each convolution layer. Height = Width')
cmd:option('-convPoolSize', '{2,2}', 'size of the max pooling of each convolution layer. Height = Width. (zero means no pooling)')
cmd:option('-convPoolStride', '{2,2}', 'stride of the max pooling of each convolution layer. Height = Width')
-- inception layers
cmd:option('-incepChannelSize', '{{32,48},{32,64}}', 'A list of tables of the number of filters in the non-1x1-convolution kernel sizes. Creates an Inception model for each sub-table.')
cmd:option('-incepReduceSize', '{{48,64,32,32},{48,64,32,32}}','Number of filters in the 1x1 convolutions (reduction) '..
   'used in each column. The last 2 are used respectively for the max pooling (projection) column '..
   '(the last column in the paper) and the column that has nothing but a 1x1 conv (the first column in the paper).'..
   'Each subtable should have two elements more than the corresponding outputSize')
cmd:option('-incepReduceStride', '{}', 'The strides of the 1x1 (reduction) convolutions. Defaults to {{1,1,1,..},...}')
cmd:option('-incepKernelSize', '{}', 'The size (height=width) of the non-1x1 convolution kernels. Defaults to {{5,3},...}, i.e. 5x5 and 3x3 for each inception layer')
cmd:option('-incepKernelStride', '{}', 'The stride (height=width) of the convolution. Defaults to {{1,1},...}.')
cmd:option('-incepPoolSize', '{}', 'The size (height=width) of the spatial max pooling used in the next-to-last column. Variables default to 3')
cmd:option('-incepPoolStride', '{}', 'The stride (height=width) of the spatial max pooling. Variables default to 1')
-- dense layers
cmd:option('-hiddenSize', '{}', 'size of the dense hidden layers after the convolution')
-- misc
cmd:option('-cuda', true, 'use CUDA')
cmd:option('-useDevice', 1, 'sets the device (GPU) to use')
cmd:option('-maxEpoch', 1000, 'maximum number of epochs to run')
cmd:option('-maxTries', 50, 'maximum number of epochs to try to find a better local minima for early-stopping')
cmd:option('-accUpdate', false, 'accumulate gradients inplace (much faster, but cant be used with momentum')
cmd:option('-progress', false, 'print progress bar')
cmd:option('-silent', false, 'dont print anything to stdout')
cmd:option('-seed', 43, 'fixed input seed for repeatable experiments')
cmd:option('-threads', 8, 'number of threads')
-- data:
cmd:option('-size', 'full', 'how many samples do we load: small | full | extra')
-- model:
cmd:option('-model', 'alexnet', 'type of model to construct: linear | mlp | convnet | volker')
-- loss:
cmd:option('-loss', 'simple', 'type of loss function to minimize: nll | mse | margin | simple')
-- training:
cmd:option('-save', 'results', 'subdirectory to save/log experiments in')
cmd:option('-plot', false, 'live plot')
cmd:option('-optimization', 'SGD', 'optimization method: SGD | ASGD | CG | LBFGS')
cmd:option('-batchForward', true, 'Forward input in batches or in a loop')
cmd:option('-weightDecay', 0.0005, 'weight decay (SGD only)')
cmd:option('-momentum', 0.9, 'momentum (SGD only)')
cmd:option('-t0', 1, 'start averaging at t0 (ASGD only), in nb of epochs')
cmd:option('-maxIter', 2, 'maximum nb of iterations for CG and LBFGS')
cmd:option('-type', 'float', 'type: double | float | cuda')
cmd:option('-visualize', false, 'visualize weights of the network (true | false)')
cmd:option('-dof', 1, 'degrees of freedom; 1: only x coordinates, 2: x, y; etc.')
cmd:option('-saveModel', true, 'Save model after each iteration')
cmd:option('-baseDir', '/home/pold/Documents/draug/', 'Base dir for images and targets')
cmd:option('-regression', true, 'Base directory for images and targets')

cmd:text()
opt = cmd:parse(arg or {})
if not opt.silent then
   table.print(opt)
end


-- convolution layers
opt.convChannelSize = table.fromString(opt.convChannelSize)
opt.convKernelSize = table.fromString(opt.convKernelSize)
opt.convKernelStride = table.fromString(opt.convKernelStride)
opt.convPoolSize = table.fromString(opt.convPoolSize)
opt.convPoolStride = table.fromString(opt.convPoolStride)
-- inception layers
opt.incepChannelSize = dp.returnString(opt.incepChannelSize)
opt.incepReduceSize = dp.returnString(opt.incepReduceSize)
opt.incepReduceStride = dp.returnString(opt.incepReduceStride)
opt.incepKernelSize = dp.returnString(opt.incepKernelSize)
opt.incepKernelStride = dp.returnString(opt.incepKernelStride) 
opt.incepPoolSize = table.fromString(opt.incepPoolSize)
opt.incepPoolStride = table.fromString(opt.incepPoolStride)
-- misc
opt.dropoutProb = table.fromString(opt.dropoutProb)
opt.hiddenSize = table.fromString(opt.hiddenSize)

--[[Model]]--
cnn = nn.Sequential()

-- convolutional and pooling layers
insize = {1, 3, 224, 224}
inputSize = insize[2]
depth = 1
for i=1,#opt.convChannelSize do
   if opt.dropout and (opt.dropoutProb[depth] or 0) > 0 then
      -- dropout can be useful for regularization
      cnn:add(nn.SpatialDropout(opt.dropoutProb[depth]))
   end
   cnn:add(nn.SpatialConvolution(
      inputSize, opt.convChannelSize[i], 
      opt.convKernelSize[i], opt.convKernelSize[i], 
      opt.convKernelStride[i], opt.convKernelStride[i],
      (not opt.dontPad) and math.floor(opt.convKernelSize[i]/2) or 0
   ))
   if opt.batchNorm then
      -- batch normalization can be awesome
      cnn:add(nn.SpatialBatchNormalization(opt.convChannelSize[i]))
   end
   cnn:add(nn[opt.activation]())
   if opt.convPoolSize[i] and opt.convPoolSize[i] > 0 then
      cnn:add(nn.SpatialMaxPooling(
         opt.convPoolSize[i], opt.convPoolSize[i], 
         opt.convPoolStride[i] or opt.convPoolSize[i], 
         opt.convPoolStride[i] or opt.convPoolSize[i]
      ))
   end
   inputSize = opt.convChannelSize[i]
   depth = depth + 1
end

-- Inception layers
for i=1,#opt.incepChannelSize do
   if opt.dropout and (opt.dropoutProb[depth] or 0) > 0 then
      -- dropout can be useful for regularization
      cnn:add(nn.SpatialDropout(opt.dropoutProb[depth]))
   end
   cnn:add(nn.Inception{
      inputSize = inputSize,
      outputSize = opt.incepChannelSize[i],
      reduceSize = opt.incepReduceSize[i],
      reduceStride = opt.incepReduceStride[i],
      kernelSize = opt.incepKernelSize[i],
      kernelStride = opt.incepKernelStride[i],
      poolSize = opt.incepPoolSize[i],
      poolStride =  opt.incepPoolStride[i],
      transfer = nn[opt.activation](),
      batchNorm = opt.batchNorm,
      padding = not opt.dontPad
   })
   inputSize = cnn:outside(insize)[2]
   depth = depth + 1
end

-- get output size of convolutional layers
outsize = cnn:outside(insize)
inputSize = outsize[2]*outsize[3]*outsize[4]
dp.vprint(not opt.silent, "input to dense layers has: "..inputSize.." neurons")

--cnn:insert(nn.Convert(trainset:ioShapes(), 'bchw'), 1)

-- dense layers
cnn:add(nn.Collapse(3))
for i,hiddenSize in ipairs(opt.hiddenSize) do
   if opt.dropout and (opt.dropoutProb[depth] or 0) > 0 then
      cnn:add(nn.Dropout(opt.dropoutProb[depth]))
   end
   cnn:add(nn.Linear(inputSize, hiddenSize))
   if opt.batchNorm then
      cnn:add(nn.BatchNormalization(hiddenSize))
   end
   cnn:add(nn[opt.activation]())
   inputSize = hiddenSize
   depth = depth + 1
end

-- output layer
if opt.dropout and (opt.dropoutProb[depth] or 0) > 0 then
   cnn:add(nn.Dropout(opt.dropoutProb[depth]))
end

-- Convert the estimations to one prediction per coordinate
if opt.regression then
      cnn:add(nn.Linear(inputSize, opt.dof))
end


return cnn
