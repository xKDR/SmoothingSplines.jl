module SmoothingSplines

import StatsBase: fit!, fit, RegressionModel, rle, ordinalrank, mean, predict
using Reexport
using LinearAlgebra
using Optim

export SmoothingSpline, smoothing_parameter

@reexport using StatsBase

LAPACKFloat = Union{Float32,Float64}

include("matrices.jl")

mutable struct SmoothingSpline{T<:LAPACKFloat} <: RegressionModel
    Xorig::Vector{T} # original grid points, but sorted
    Yorig::Vector{T} # original values, sorted according to x
    Xrank::Vector{Int}
    Xdesign::Vector{T}
    Xcount::Vector{Int} # to how many observations does X correspond?
    Ydesign::Vector{T}
    weights::Vector{T} # don't implement this yet.
    RpαQtQ::Matrix{T} # in symmetric banded matrix format
    g::Vector{T} # fitted values
    γ::Vector{T} # 2nd derivatives of fitted vals
    λ::T
end

function fit(::Type{SmoothingSpline}, X::AbstractVector{T}, Y::AbstractVector{T}, λ::T, wts::AbstractVector{T}=fill(1.0, length(Y))) where T <: LAPACKFloat
    Xrank = ordinalrank(X) # maybe speed this up when already sorted
    Xperm = sortperm(X)
    Xorig = X[Xperm]
    Yorig = Y[Xperm]

    Xdesign, Xcount = rle(Xorig)
    ws = zero(Xdesign)
    Ydesign = zero(Xdesign)
    running_rle_mean!(Ydesign, ws, Yorig, Xcount, wts[Xperm])

    RpαQtQ = QtQpR(diff(Xdesign), λ, ws)
    pbtrf!('U', 2, RpαQtQ)

    spl = SmoothingSpline{T}(Xorig, Yorig, Xrank, Xdesign, Xcount, Ydesign, ws, RpαQtQ,
                             zero(Xdesign), fill(zero(T),length(Xdesign)-2), λ)
    fit!(spl)
end

"""
Applying Leave one out cross-validation if λ isn't provided and returning the SmoothingSpline model. 
Here we applied Leave One Out cross-validation(LOOCV) manually and optimising it with Optim Package. 
The LOO function will return training and testing indices, and smoothing_parameter will find the 
optimize λ for the DataSet. Here calculating the absolute difference between test value and predicted value 
and taking their mean as a score. 
"""
function fit(::Type{SmoothingSpline}, X::AbstractVector, Y::AbstractVector, wts::AbstractVector{T}=fill(1.0, length(Y))) where T <: LAPACKFloat
    function LOO(n) #funtion for leave one out cross validation
        test_inds = []
        train_inds = []
        for i in 1:n
            push!(test_inds, i)
            train_ind = vcat(1:i-1, i+1:n)
            push!(train_inds, train_ind)
        end
        # returning the train indices and test indices in two array with the indices as an element
        return (train_inds, test_inds) 
    end

    function smoothing_parameter(X, Y) #function for choosing optimize smoothing_parameter λ
        function smoothcvloo(λ)
            n = length(X)
            train_inds, test_inds = LOO(n)
            X_std = (X .- minimum(X))/(maximum(X)-minimum(X))
            avgrss = []
            for i in 1:n
                xtest = X_std[test_inds[i]]
                ytest = Y[test_inds[i]]
                xtrain = X_std[train_inds[i]]
                ytrain = Y[train_inds[i]]
                spl = fit(SmoothingSpline, xtrain, ytrain, λ)
                Ypred = predict(spl,xtest)
                push!(avgrss, abs(ytest - Ypred))
            end
            return mean(avgrss)
        end
        res = optimize(smoothcvloo, 0.0, 1000.0) # optimizing λ
        λ = Optim.minimizer(res)    
        println("Parameter:", λ) #optimized λ
        return λ
    end
    return fit(SmoothingSpline, X, Y, smoothing_parameter(X, Y)) #return the model with optimized parameter
end

function fit!(spl::SmoothingSpline{T}) where T<:LAPACKFloat
    Y = spl.Ydesign
    ws = spl.weights
    g = spl.g
    n = length(spl.g)
    h = diff(spl.Xdesign)
    λ = spl.λ
    Q = ReinschQ(h)

    RpαQtQ = spl.RpαQtQ
    γ = mul!(spl.γ, transpose(Q), Y) #Q^T*Y
    pbtrs!('U', 2, RpαQtQ, γ)
    mul!(g, Q, γ)
    broadcast!(/, g, g, ws)
    broadcast!(*, g, g, λ)
    broadcast!(-,g, Y, g)
    spl
end

function fit!(spl::SmoothingSpline{T}, Y::AbstractVector{T}) where T<:LAPACKFloat
    spl.Y = Y[spl.idx]
    fit!(spl)
end


function predict(spl::SmoothingSpline{T}) where T<:LAPACKFloat
    # need to convert back from RLE encoding
    Xcount = spl.Xcount
    curridx = 1::Int
    g = fill(0.0, length(spl.Yorig))
    @inbounds for i=1:length(Xcount)
        @inbounds   for j=1:Xcount[i]
            g[curridx] = spl.g[i]
            curridx += 1
        end
    end
    g[spl.Xrank]
end

function predict(spl::SmoothingSpline{T}, x::T) where T<:LAPACKFloat
    n = length(spl.Xdesign)
    idxl = searchsortedlast(spl.Xdesign, x)
    idxr = idxl + 1
    if idxl == 0 # linear extrapolation to the left
        gl = spl.g[1]
        gr = spl.g[2]
        γ  = spl.γ[1]
        xl = spl.Xdesign[1]
        xr = spl.Xdesign[2]
        gprime = (gr-gl)/(xr-xl) - 1/6*(xr-xl)*γ
        val = gl - (xl-x)*gprime
    elseif idxl == n # linear extrapolation to the right
        gl = spl.g[n-1]
        gr = spl.g[n]
        γ  = spl.γ[n-2]
        xl = spl.Xdesign[n-1]
        xr = spl.Xdesign[n]
        gprime = (gr-gl)/(xr-xl) +1/6*(xr-xl)*γ
        val = gr + (x - xr)*gprime
    else # cubic interpolation
        xl = spl.Xdesign[idxl]
        xr = spl.Xdesign[idxr]
        γl = idxl == 1 ? zero(T) : spl.γ[idxl-1]
        γr = idxl == n-1 ? zero(T) : spl.γ[idxr-1]
        gl = spl.g[idxl]
        gr = spl.g[idxr]
        h = xr-xl
        val = ((x-xl)*gr + (xr-x)*gl)/h
        val -=  1/6*(x-xl)*(xr-x)*((1 + (x-xl)/h)*γr + (1+ (xr-x)/h)*γl)
    end
    val
end

function predict(spl::SmoothingSpline{T}, xs::AbstractVector{T}) where T<:SmoothingSplines.LAPACKFloat
    g = zero(xs)
    for (i,x) in enumerate(xs)
        # can be made more efficient as in StatsBase ECDF code
        g[i] = predict(spl, x)
    end
    g
end

# update g and w in place
function running_rle_mean!(g::AbstractVector{T}, w::AbstractVector{T}, Y::AbstractVector{T}, rlecount::AbstractVector{Int}, ws::AbstractVector{T}) where T<:Real
  length(g) == length(rlecount) ||  throw(DimensionMismatch())
  length(Y) == length(ws) || throw(DimensionMismatch())
  curridx = 1::Int
  for i=1:length(rlecount)
    idxrange = curridx:(curridx+rlecount[i]-1)
    g[i] = mean(Y[idxrange], Weights(ws[idxrange])) #todo: use weights by default
    w[i] = sum(ws[idxrange])
    curridx += rlecount[i]
  end
  g
end


end # module
