using Revise
using ADSeismic
using ADCME
using MAT
using PyPlot
using PyCall
using DelimitedFiles
# matplotlib.use("Agg")
close("all")
if has_gpu()
  gpu = true
else
  gpu = false
end

data_dir = "data/acoustic"
if !ispath(data_dir)
  mkpath(data_dir)
end
figure_dir = "figure/PhysGNN_V1/"
if !ispath(figure_dir)
  mkpath(figure_dir)
end
result_dir = "result/PhysGNN_V1/"
if !ispath(result_dir)
  mkpath(result_dir)
end
# if isfile(joinpath(result_dir, "loss.txt"))
#   rm(joinpath(result_dir, "loss.txt"))
# end

################### Inversion using Automatic Differentiation #####################
reset_default_graph()
batch_size = 8 ## number of models per source
sample_size = 8 ## number of sampled y per source
model_name = "models/marmousi2-model-smooth.mat"

## load model
params = load_params(model_name)
src = load_acoustic_source(model_name)
rcv = load_acoustic_receiver(model_name)
nsrc = length(src)

## assume receivers are the same for all sources
rcv = [load_acoustic_receiver(model_name)[1] for i = 1:batch_size] 

vp0 = matread(model_name)["vp"]
mean_vp0 = mean(vp0)
std_vp0 = std(vp0)
vp0 = constant(vp0)

## load data
Rs = Array{Array{Float64,2}}(undef, length(src))
for i = 1:length(src)
    Rs[i] = readdlm(joinpath(data_dir, "marmousi-r$i.txt"))
end

## original fwi
# vp_ = Variable(vp0 / mean_vp0)
# vp = vp_ * mean_vp0
# vars = vp_

## add NN
x, isTrain, y, z = sampleUQ(batch_size, sample_size, (size(src[1].srcv,1)+1,length(rcv[1].rcvi)), 
                            z_size=8, base=4, ratio=size(vp0)[1]/size(vp0)[2]) 
x = x * std_vp0
vp = vp0 + tf.slice(x, (size(x).-(size(x)[1], size(vp0)...)).÷2, (size(x)[1], size(vp0)...))

## assemble acoustic propagator model
# model = x->AcousticPropagatorSolver(params, x, vp^2)
models = Array{Any}(undef, batch_size)
for i = 1:batch_size
  vp = vp0 + tf.slice(x[i], (size(x[i]).-size(vp0)).÷2, size(vp0))
  models[i] = x->AcousticPropagatorSolver(params, x, vp^2)
end

@pywith tf.device("/cpu:0") begin
  global variable_rcv_ = placeholder(Float64, shape=size(Rs[1]))
  Rs_ = [variable_rcv_ + y[i] for i = 1:sample_size]

  global si_ = placeholder(Int32, shape=[length(src[1].srci)])
  global sj_ = placeholder(Int32, shape=[length(src[1].srcj)])
  global sv_ = placeholder(Float64, shape=size(src[1].srcv))
  variable_src = AcousticSource(si_, sj_, sv_)

  global loss, dd = sampling_compute_loss_and_grads_GPU(models, variable_src, rcv, Rs_, 200.0)
end

lr = 0.001
opt = AdamOptimizer(lr).minimize(loss, colocate_gradients_with_ops=true)

i = rand(1:nsrc)
dic = Dict(
  isTrain=>true,
  z=>randn(Float32, size(z)...),
  y=>randn(size(y)...),
  si_=>src[i].srci,
  sj_=>src[i].srcj,
  sv_=>src[i].srcv,
  variable_rcv_=>Rs[i]
)

sess = Session(); init(sess)
@info "Initial loss: ", run(sess, loss, feed_dict=dic)

losses = []
σ = 0.01
fixed_z = randn(Float32, size(z)...)
time = 0
for iter = 1:10000
    if iter%50==1
      dic = Dict(
        isTrain=>true,
        z=>fixed_z
      )
      plot_result(sess, x, dic, iter, dirs=figure_dir, var_name="x")
      plot_result(sess, vp, dic, iter, dirs=figure_dir, var_name="vp")
    end

    dic = Dict(
      isTrain=>true,
      z=>randn(Float32, size(z)...),
      y=>randn(size(y)...) * σ * std(Rs[i]),
      si_=>src[i].srci,
      sj_=>src[i].srcj,
      sv_=>src[i].srcv,
      variable_rcv_=>Rs[i]
    )
    
    global time += @elapsed ls, _ = run(sess, [loss, opt], feed_dict=dic)
    if iter == 1
      global mean_ls = ls
    else
      global mean_ls
      mean_ls += 1/(iter+1) * (ls - mean_ls)
    end
    # println("[#$iter] loss = $loss_, mean loss = $mean_loss")
    println("   $iter\t$ls\t$mean_ls")
    println(" * time: $time")
    push!(losses, ls)
end