function LOO(n)
    test_inds = []
    train_inds = []
    for i in 1:n
        push!(test_inds, i)
        train_ind = vcat(1:i-1, i+1:n)
        push!(train_inds, train_ind)
    end
    return (train_inds, test_inds) 

end

function smoothing_parameter(X, Y)
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
    res = optimize(smoothcvloo, 0.0, 1.0)
    λ = Optim.minimizer(res)    
    return λ
end
