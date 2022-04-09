using SmoothingSplines
X = rand(1:10.0, 10)
Y = rand(1:10.0, 10)
fit(SmoothingSpline, X, Y)