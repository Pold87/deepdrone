require 'torch'   -- torch
require 'xlua'    -- xlua provides useful tools, like progress bars
require 'optim'   -- an optimization package, for online and batch methods
require 'math'


-- parse command line arguments
if not opt then
   print '==> processing options'
   cmd = torch.CmdLine()
   cmd:text()
   cmd:text('Deep Drone Training/Optimization')
   cmd:text()
   cmd:text('Options:')
   cmd:option('-save', 'results', 'subdirectory to save/log experiments in')
   cmd:option('-visualize', false, 'visualize input data and weights during training')
   cmd:option('-plot', false, 'live plot')
cmd:option('-optimization', 'SGD', 'optimization method: SGD | ASGD | CG | LBFGS | ADADELTA | ADAGRAD (recommended)')
   cmd:option('-learningRate', 1e-3, 'learning rate at t=0')
   cmd:option('-batchSize', 5, 'mini-batch size (1 = pure stochastic)')
   cmd:option('-weightDecay', 0, 'weight decay (SGD only)')
   cmd:option('-momentum', 0, 'momentum (SGD only)')
   cmd:option('-t0', 1, 'start averaging at t0 (ASGD only), in nb of epochs')
   cmd:option('-maxIter', 2, 'maximum nb of iterations for CG and LBFGS')
   cmd:option('-saveModel', false, 'Save model after each iteration')
   cmd:text()
   opt = cmd:parse(arg or {})
end

-- CUDA?
if opt.type == 'cuda' then

   trainset.data = trainset.data:cuda()
   trainset.label = trainset.label:cuda()

   model:cuda()
   criterion:cuda()
end


----------------------------------------------------------------------
print '==> defining some tools'

classes = {'1','2','3','4','5','6','7','8','9', '10'}

-- This matrix records the current confusion across classes
confusion = optim.ConfusionMatrix(classes)

-- Log results to files
trainLogger = optim.Logger(paths.concat(opt.save, 'train.log'))
testLogger = optim.Logger(paths.concat(opt.save, 'test.log'))

-- Retrieve parameters and gradients:
-- this extracts and flattens all the trainable parameters of the mode
-- into a 1-dim vector
if model then
   parameters,gradParameters = model:getParameters()
end

----------------------------------------------------------------------
print '==> configuring optimizer'

if opt.optimization == 'CG' then
   optimState = {
      maxIter = opt.maxIter
   }
   optimMethod = optim.cg

elseif opt.optimization == 'LBFGS' then
   optimState = {
      learningRate = opt.learningRate,
      maxIter = opt.maxIter,
      nCorrection = 10
   }
   optimMethod = optim.lbfgs

elseif opt.optimization == 'SGD' then
   optimState = {
      learningRate = opt.learningRate,
      weightDecay = opt.weightDecay,
      momentum = opt.momentum,
      learningRateDecay = 1e-7
   }
   optimMethod = optim.sgd

elseif opt.optimization == 'ASGD' then
   optimState = {
      eta0 = opt.learningRate,
      t0 = trsize * opt.t0
   }
   optimMethod = optim.asgd

elseif opt.optimization == 'ADADELTA' then
   optimState = {
      t0 = trsize * opt.t0
   }
   optimMethod = optim.adadelta

elseif opt.optimization == 'ADAGRAD' then
   optimState = {
      t0 = trsize * opt.t0
   }
   optimMethod = optim.adagrad

else
   error('unknown optimization method')
end

print '==> defining training procedure'

function train()

   -- epoch tracker
   epoch = epoch or 1

   -- local vars
   local time = sys.clock()

   -- set model to training mode (for modules that differ in training and testing, like Dropout)
   model:training()

   -- shuffle at each epoch
   shuffle = torch.randperm(trsize)

   local batchIdx = 0

   -- do one epoch
   print('==> doing epoch on training data:')
   print("==> online epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ']')
   for t = 1,trainset:size(),opt.batchSize do

      batchIdx = 0

      -- disp progress
      xlua.progress(t, trainset:size())

      -- create mini batch
      local inputs = {}
      local targets = {}

      local batchData = torch.Tensor(opt.batchSize, 3, img_width, img_height)
      local batchLabels = torch.Tensor(opt.batchSize, opt.dof, total_range)

      if opt.type == 'cuda' then
         batchData = batchData:cuda()
         batchLabels = batchLabels:cuda()
      end

      -- Generate patches
      for i = t, math.min(t+opt.batchSize-1,trainset:size()) do

         batchIdx = batchIdx + 1

         local input = trainset.data[shuffle[i]]
         local target = trainset.label[shuffle[i]]

         if opt.type == 'double' then
            input = input:double()
         elseif opt.type == 'cuda' then 
            input = input:cuda() 
            target = target:cuda() 
         end
         table.insert(inputs, input)
         table.insert(targets, target)

         batchData[batchIdx] = input
         batchLabels[batchIdx] = target

      end

      -- create closure to evaluate f(X) and df/dX
      local feval = function(x)
                       -- get new parameters
                       if x ~= parameters then
                          parameters:copy(x)
                       end

                       -- reset gradients
                       gradParameters:zero()

                       -- f is the average of all criterions
                       local f = 0

                       if opt.batchForward then

                          local output = model:forward(batchData)

                          local err = criterion:forward(output, batchLabels)
                          f = f + err

                          -- estimate df/dW
                          local df_do = criterion:backward(output, batchLabels)
                          model:backward(batchData, df_do)

                          -- update confusion
			  
			if opt.model == 'disable' then

                          confusion:add(to_classes(output[1], 10), 
                                        to_classes(batchLabels[1][1], 10))
		
			else

                          confusion:batchAdd(all_classes_2d(model.output, 10), 
                                             all_classes(batchLabels, 10))

                       end

		       else

                       -- evaluate function for complete mini batch
                        for i = 1, #inputs do

                          -- estimate f
                          local output = model:forward(inputs[i])

                          local err = criterion:forward(output, targets[i])
                          f = f + err

                          -- estimate df/dW
                          local df_do = criterion:backward(output, targets[i])
                          model:backward(inputs[i], df_do)

                          -- update confusion
                          confusion:add(to_classes(output[1], 10), 
                                        to_classes(targets[i][1], 10))
                        end


                       end

                       -- normalize gradients and f(X)
                       gradParameters:div(#inputs)
                       f = f/#inputs

                       -- return f and df/dX
                       return f, gradParameters
                    end

      -- optimize on current mini-batch
      if optimMethod == optim.asgd then
         _,_,average = optimMethod(feval, parameters, optimState)
      else
         optimMethod(feval, parameters, optimState)
      end
   end

   -- time taken
   time = sys.clock() - time
   time = time / trainset:size()
   print("\n==> time to learn 1 sample = " .. (time*1000) .. 'ms')

   -- print confusion matrix
   print(confusion)

   -- update logger/plot
   trainLogger:add{['% mean class accuracy (train set)'] = confusion.totalValid * 100}
   if opt.plot then
      trainLogger:style{['% mean class accuracy (train set)'] = '-'}
      trainLogger:plot()
      

   end

   -- save/log current model

   if opt.saveModel then

      local filename = paths.concat(opt.save, 'model.t7')
      os.execute('mkdir -p ' .. sys.dirname(filename))
      print('==> saving model to '..filename)
      torch.save(filename, model)
   end

   -- next epoch
   confusion:zero()
   epoch = epoch + 1
end
