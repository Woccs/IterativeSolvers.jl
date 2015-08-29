#Matrix of the form
# d1          a_1
#    d2       a_2
#      ...    ...
#         d_l a_l
#             d_l+1 e_l+1
#                   ...  e_k-1
#                        d_k
type BrokenArrowBidiagonal{T} <: AbstractMatrix{T}
    dv::Vector{T}
    av::Vector{T}
    ev::Vector{T}
end
Base.size(B::BrokenArrowBidiagonal) = (n=length(B.dv); (n, n))
function Base.size(B::BrokenArrowBidiagonal, n::Int)
    if n==1 || n==2
        return length(B.dv)
    else
        throw(ArgumentError("invalid dimension $n"))
    end
end
function Base.full{T}(B::BrokenArrowBidiagonal{T})
    n = size(B, 1)
    k = length(B.av)
    M = zeros(T, n, n)
    for i=1:n
        M[i, i] = B.dv[i]
    end
    for i=1:k
        M[i,k+1] = B.av[i]
    end
    for i=k+1:n-1
        M[i, i+1] = B.ev[i-k]
    end
    M
end

Base.svdfact(B::BrokenArrowBidiagonal) = svdfact(full(B))

type BidiagonalFactorization{T, Tr} <: Factorization{T}
    P :: T
    Q :: T
    B :: Union(Bidiagonal{Tr}, BrokenArrowBidiagonal{Tr})
    β :: Tr
end



"""
The thick-restarted variant of Golub-Kahan-Lanczos bidiagonalization

# Inputs

- `A` : The matrix or matrixlike object whose singular values are desired
- `q` : The starting guess vector in the range of `A`.
        The length of `q` should be the number of columns in `A`.
- `l` : The number of singular values requested.
        Default: 6
- `k` : The maximum number of Lanczos vectors to compute before restarting.
        Default: `2*l`

# Keyword inputs

- `maxiter`: Maximum number of iterations to run
             Default: `minimum(size(A))`
- `tol`    : Maximum error in each desired singular value.
             Default: `√eps()`

# Output

# Implementation notes

This implementation follows closely that of SLEPc as described in
[Hernandez2008].

# References

@article{Hernandez2008,
    author = {Hern\'{a}ndez, Vicente and Rom\'{a}n, Jos\'{e} E and Tom\'{a}s,
    Andr\'{e}s},
    journal = {Electronic Transactions on Numerical Analysis},
    pages = {68--85},
    title = {A Robust and Efficient Parallel {SVD} Solver based on Restarted
        {L}anczos Bidiagonalization},
    url = {http://etna.mcs.kent.edu/volumes/2001-2010/vol31/abstract.php?vol=31\&pages=68-85},
    volume = 31,
    year = 2008
}

"""

function thickrestartbidiag(A, q::AbstractVector, l::Int=6, k::Int=2l;
    maxiter::Int=minimum(size(A)), tol::Real=√eps())

    @assert k>l
    L = build(A, q, k)

    local F
    for i=1:maxiter
        info("Iteration $i")
        #@assert size(L.B) == (k, k)
        F = svdfact(L.B)
        L = truncate!(A, L, F, l)
        extend!(A, L, k)
        isconverged(L, F, l, tol) && break
    end
    F[:S][1:l], L
end

"""

# References

The simple error bound dates back at least to Wilkinson's classic book
[Wilkinson1965:Ch.3 §53 p.170]

@book{Wilkinson1965,
    address = {Oxford, UK},
    author = {J H Wilkinson},
    publisher = {Oxford},
    title = {The Algebraic Eigenvalue Problem},
    year = 1965
}

The Rayleigh-Ritz bounds were presented in [Wilkinson1965:Ch.3 §54-55 p.173,
    Yamamoto1980, Ortega1990]

@book{Ortega1990,
    address = {Philadelphia, PA},
    author = {Ortega, James M},
    doi = {10.1137/1.9781611971323},
    edition = {2},
    publisher = {SIAM},
    series = {Classics in Applied Mathematics},
    title = {Numerical Analysis: A Second Course},
    url = {http://epubs.siam.org/doi/book/10.1137/1.9781611971323},
    year = 1990
}

@article{Yamamoto1980,
    author = {Yamamoto, Tetsuro},
    doi = {10.1007/BF01396059},
    journal = {Numerische Mathematik},
    number = 2,
    pages = {189--199},
    title = {Error bounds for computed eigenvalues and eigenvectors},
    volume = {34},
    year = 1980
}

"""
function isconverged(L::BidiagonalFactorization,
        F::Base.LinAlg.SVD, k::Int, tol::Real)

    @assert tol ≥ 0

    σ = F[:S][1:k]
    Δσ= L.β*abs(F[:U][end, 1:k])

    #Best available eigenvalue bounds
    δσ = copy(Δσ)

    #Update better error bounds from Rayleigh-Ritz
    #Reference: Ortega, 1972
    #In theory these only apply if we know all the values
    #But so long as the gap between the converged Ritz values and all the
    #others is larger than d then we're fine.
    #Can also get some eigenvector statistics!!
    let
        d = Inf
        for i in eachindex(σ), j=1:i-1
            d = min(d, abs(σ[i] - σ[j]))
        end
        println("Smallest empirical spectral gap: ", d)
        #Chatelein 1993 - normwise backward error associated with approximate invariant subspace
        #Use the largest singular (Ritz) value to estimate the 2-norm of the matrix
        println("Normwise backward error associated with subspace: ", L.β/σ[1])
        for i in eachindex(Δσ)
            α = Δσ[i]

            #Simple error bound
            println("Ritz value ", i, ": ", σ[i])
            println("Simple error bound on eigenvalue: ", Δσ[i])

            if 2α ≤ d
                #Rayleigh-Ritz bounds
                x = α/(d-α)*√(1+(α/(d-α))^2)
                println("Rayleigh-Ritz error bound on eigenvector: $x")
                δσ[i] = min(δσ[i], x)

                y = α^2/d #[Wilkinson:Ch.3 Appendix (4), p.188]
                println("Rayleigh-Ritz error bound on eigenvalue: $y")
                δσ[i] = min(δσ[i], y)
            end

            #Estimate of the normwise backward error [Deif 1989]
            #Use the largest singular (Ritz) value to estimate the 2-norm of the matrix
            println("Normwise backward error estimate: ", α/σ[1])

            #Geurts, 1982 - componentwise backward error also known


        end
    end

    all(δσ[1:k] .< tol)
end

function build{T}(A, q::AbstractVector{T}, k::Int)
    m, n = size(A)
    Tr = typeof(real(one(T)))

    P = Array(T, m, k)
    Q = Array(T, n, k+1)
    αs= Array(Tr, k)
    βs= Array(Tr, k-1)
    Q[:, 1] = q
    local β
    p = Array(T, m)
    for j=1:k
        #p = A*q
        A_mul_B!(p, A, q)
        if j>1
            βs[j-1] = β
            Base.LinAlg.axpy!(-β, sub(P, :, j-1), p) #p -= β*P[:,j-1]
        end
        α = norm(p)
        p[:] = p/α

        αs[j] = α
        P[:, j] = p

        Ac_mul_B!(q, A, p) #q = A'p
        Base.LinAlg.axpy!(-1.0, sub(Q, :, 1:j)*(sub(Q, :, 1:j)'q), q) #orthogonalize

        β = norm(q)
        q[:] = q/β
        Q[:,j+1] = q
    end
    BidiagonalFactorization(P, Q, Bidiagonal(αs, βs, true), β)
end

#By default, truncate to l largest singular triplets
function truncate!(A, L::BidiagonalFactorization,
        F::Base.LinAlg.SVD, l::Int)

    k = size(F[:V], 1)
    m, n = size(A)
    @assert size(L.P) == (m, k)
    @assert size(L.Q) == (n, k+1)

    L.Q = [sub(L.Q, :,1:k)*sub(F[:V], :,1:l) sub(L.Q, :, k+1)]
    #Be pedantic about ensuring normalization
    #L.Q = qr(L.Q)[1]
    #@assert all([norm(L.Q[:,i]) ≈ 1 for i=1:size(L.Q,2)])

    f = A*sub(L.Q, :, l+1)
    ρ = L.β * reshape(F[:U][end, 1:l], l)
    L.P = sub(L.P, :, 1:k)*sub(F[:U], :, 1:l)

    #@assert ρ[i] ≈ f⋅L.P[:, i]
    f -= L.P*ρ
    α = norm(f)
    f[:] = f/α
    L.P = [L.P f]

    g = A'f - α*L.Q[:, end]
    β = norm(g)
    g[:] = g/β
    L.β = β
    L.B = BrokenArrowBidiagonal([F[:S][1:l]; α], ρ, typeof(β)[])

    L
end

function extend!(A, L::BidiagonalFactorization, k::Int)
    l = size(L.P, 2)-1
    p = L.P[:, end]

    local β
    m, n = size(A)
    q = zeros(n)
    for j=l+1:k
        Ac_mul_B!(q, A, p) #q = A'p
        q -= L.Q*(L.Q'q)   #orthogonalize
        β = norm(q)
        q[:] = q/β
        push!(L.B.ev, β)

        L.Q = [L.Q q]
        j==k && break

        #p = A*q - β*p
        A_mul_B!(p, A, q)
        Base.LinAlg.axpy!(-β, sub(L.P, :, j), p)

        α = norm(p)
        p[:] = p/α
        push!(L.B.dv, α)
        L.P = [L.P p]
    end
    L.β = β
    L
end

let
    B = BrokenArrowBidiagonal([1, 2, 3], [1, 2], Int[])
    @assert full(B) == [1 0 1; 0 2 2; 0 0 3]
end

let
    srand(1)
    m = 300
    n = 200
    k = 5
    l = 10

    A = randn(m,n)
    q = randn(n)|>x->x/norm(x)
    σ, L = thickrestartbidiag(A, q, k, l, tol=1e-5)
    @assert norm(σ - svdvals(A)[1:k]) < k^2*1e-5
end

let
    srand(1)
    m = 30000
    n = 20000
    k = 5
    l = 10

    A = sprandn(m,n,0.1)
    q = randn(n)|>x->x/norm(x)
    @time thickrestartbidiag(A, q, k, l, tol=1e-5)
end

