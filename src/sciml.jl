"""
    MatrixOperator(A[; update_func])

Represents a time-dependent linear operator given by an AbstractMatrix. The
update function is called by `update_coefficients!` and is assumed to have
the following signature:

    update_func(A::AbstractMatrix,u,p,t) -> [modifies A]
"""
struct MatrixOperator{T,AType<:AbstractMatrix{T},F} <: AbstractSciMLLinearOperator{T}
    A::AType
    update_func::F
    MatrixOperator(A::AType; update_func=DEFAULT_UPDATE_FUNC) where{AType} =
        new{eltype(A),AType,typeof(update_func)}(A, update_func)
end

# constructors
Base.similar(L::MatrixOperator, ::Type{T}, dims::Dims) where{T} = MatrixOperator(similar(L.A, T, dims))

# traits
@forward MatrixOperator.A (
                           LinearAlgebra.issymmetric,
                           LinearAlgebra.ishermitian,
                           LinearAlgebra.isposdef,

                           issquare,
                           has_ldiv,
                           has_ldiv!,
                          )
Base.size(L::MatrixOperator) = size(L.A)
for op in (
           :adjoint,
           :transpose,
          )
    @eval function Base.$op(L::MatrixOperator)
        MatrixOperator(
                       $op(L.A);
                       update_func = (A,u,p,t) -> $op(L.update_func(L.A,u,p,t))
                      )
    end
end

has_adjoint(A::MatrixOperator) = has_adjoint(A.A)
update_coefficients!(L::MatrixOperator,u,p,t) = (L.update_func(L.A,u,p,t); L)

isconstant(L::MatrixOperator) = L.update_func == DEFAULT_UPDATE_FUNC
Base.iszero(L::MatrixOperator) = iszero(L.A)

SparseArrays.sparse(L::MatrixOperator) = sparse(L.A)

# TODO - add tests
# propagate_inbounds here for the getindex fallback
Base.@propagate_inbounds Base.convert(::Type{AbstractMatrix}, L::MatrixOperator) = L.A
Base.@propagate_inbounds Base.setindex!(L::MatrixOperator, v, i::Int) = (L.A[i] = v)
Base.@propagate_inbounds Base.setindex!(L::MatrixOperator, v, I::Vararg{Int, N}) where{N} = (L.A[I...] = v)

Base.eachcol(L::MatrixOperator) = eachcol(L.A)
Base.eachrow(L::MatrixOperator) = eachrow(L.A)
Base.length(L::MatrixOperator) = length(L.A)
Base.iterate(L::MatrixOperator,args...) = iterate(L.A,args...)
Base.axes(L::MatrixOperator) = axes(L.A)
Base.eachindex(L::MatrixOperator) = eachindex(L.A)
Base.IndexStyle(::Type{<:MatrixOperator{T,AType}}) where{T,AType} = Base.IndexStyle(AType)
Base.copyto!(L::MatrixOperator, rhs) = (copyto!(L.A, rhs); L)
Base.copyto!(L::MatrixOperator, rhs::Base.Broadcast.Broadcasted{<:StaticArrays.StaticArrayStyle}) = (copyto!(L.A, rhs); L)
Base.Broadcast.broadcastable(L::MatrixOperator) = L
Base.ndims(::Type{<:MatrixOperator{T,AType}}) where{T,AType} = ndims(AType)
ArrayInterfaceCore.issingular(L::MatrixOperator) = ArrayInterfaceCore.issingular(L.A)
Base.copy(L::MatrixOperator) = MatrixOperator(copy(L.A);update_func=L.update_func)

getops(L::MatrixOperator) = (L.A)

# operator application
Base.:*(L::MatrixOperator, u::AbstractVector) = L.A * u
Base.:\(L::MatrixOperator, u::AbstractVector) = L.A \ u
LinearAlgebra.mul!(v::AbstractVector, L::MatrixOperator, u::AbstractVector) = mul!(v, L.A, u)
LinearAlgebra.mul!(v::AbstractVector, L::MatrixOperator, u::AbstractVector, α, β) = mul!(v, L.A, u, α, β)
LinearAlgebra.ldiv!(v::AbstractVector, L::MatrixOperator, u::AbstractVector) = ldiv!(v, L.A, u)
LinearAlgebra.ldiv!(L::MatrixOperator, u::AbstractVector) = ldiv!(L.A, u)

for op in (
           :+, :-,
          )

    @eval function Base.$op(A::AbstractMatrix, L::AbstractSciMLOperator)
        @assert size(A) == size(L)
        $op(MatrixOperator(A), $op(L))
    end
    @eval function Base.$op(L::AbstractSciMLOperator, A::AbstractMatrix)
        @assert size(A) == size(L)
        $op(L, MatrixOperator($op(A)))
    end
end

function Base.:*(A::AbstractMatrix, L::AbstractSciMLOperator)
    @assert size(A) == size(L)
    *(MatrixOperator(A), L)
end
function Base.:*(L::AbstractSciMLOperator, A::AbstractMatrix)
    @assert size(A) == size(L)
    *(L, MatrixOperator(A))
end

""" Diagonal Operator """
DiagonalOperator(u::AbstractArray) = MatrixOperator(Diagonal(_vec(u)))
LinearAlgebra.Diagonal(L::MatrixOperator) = MatrixOperator(Diagonal(L.A))

"""
    InvertibleOperator(F)

Like MatrixOperator, but stores a Factorization instead.

Supports left division and `ldiv!` when applied to an array.
"""
# diagonal, bidiagonal, adjoint(factorization)
struct InvertibleOperator{T,FType} <: AbstractSciMLLinearOperator{T}
    F::FType

    function InvertibleOperator(F)
        @assert has_ldiv(F) | has_ldiv!(F) "$F is not invertible"
        new{eltype(F),typeof(F)}(F)
    end
end

# constructor
function LinearAlgebra.factorize(L::AbstractSciMLLinearOperator)
    fact = factorize(convert(AbstractMatrix, L))
    InvertibleOperator(fact)
end

for fact in (
             :lu, :lu!,
             :qr, :qr!,
             :cholesky, :cholesky!,
             :ldlt, :ldlt!,
             :bunchkaufman, :bunchkaufman!,
             :lq, :lq!,
             :svd, :svd!,
            )

    @eval LinearAlgebra.$fact(L::AbstractSciMLLinearOperator, args...) =
        InvertibleOperator($fact(convert(AbstractMatrix, L), args...))
    @eval LinearAlgebra.$fact(L::AbstractSciMLLinearOperator; kwargs...) =
        InvertibleOperator($fact(convert(AbstractMatrix, L); kwargs...))
end

function Base.convert(::Type{AbstractMatrix}, L::InvertibleOperator)
    if L.F isa Adjoint
        convert(AbstractMatrix,L.F')'
    else
        convert(AbstractMatrix, L.F)
    end
end

# traits
Base.size(L::InvertibleOperator) = size(L.F)
Base.adjoint(L::InvertibleOperator) = InvertibleOperator(L.F')
LinearAlgebra.opnorm(L::InvertibleOperator{T}, p=2) where{T} = one(T) / opnorm(L.F)
LinearAlgebra.issuccess(L::InvertibleOperator) = issuccess(L.F)

getops(L::InvertibleOperator) = (L.F,)

@forward InvertibleOperator.F (
                               # LinearAlgebra
                               LinearAlgebra.issymmetric,
                               LinearAlgebra.ishermitian,
                               LinearAlgebra.isposdef,

                               # SciML
                               isconstant,
                               has_adjoint,
                               has_mul,
                               has_mul!,
                               has_ldiv,
                               has_ldiv!,
                              )

# operator application
Base.:*(L::InvertibleOperator, x::AbstractVector) = L.F * x
Base.:\(L::InvertibleOperator, x::AbstractVector) = L.F \ x
LinearAlgebra.mul!(v::AbstractVector, L::InvertibleOperator, u::AbstractVector) = mul!(v, L.F, u)
LinearAlgebra.mul!(v::AbstractVector, L::InvertibleOperator, u::AbstractVector,α, β) = mul!(v, L.F, u, α, β)
LinearAlgebra.ldiv!(v::AbstractVector, L::InvertibleOperator, u::AbstractVector) = ldiv!(v, L.F, u)
LinearAlgebra.ldiv!(L::InvertibleOperator, u::AbstractVector) = ldiv!(L.F, u)

"""
    L = AffineOperator(A, b)
    L(u) = A*u + b
"""
struct AffineOperator{T,AType,bType} <: AbstractSciMLOperator{T}
    A::AType
    b::bType

    function AffineOperator(A::AbstractSciMLOperator, b::AbstractVector)
        T = promote_type(eltype.((A,b))...)
        new{T,typeof(A),typeof(b)}(A, b)
    end
end

getops(L::AffineOperator) = (L.A, L.b)
Base.size(L::AffineOperator) = size(L.A)

islinear(::AffineOperator) = false
Base.iszero(L::AffineOperator) = all(iszero, getops(L))
has_adjoint(L::AffineOperator) = all(has_adjoint, L.ops)
has_mul!(L::AffineOperator) = has_mul!(L.A)
has_ldiv(L::AffineOperator) = has_ldiv(L.A)
has_ldiv!(L::AffineOperator) = has_ldiv!(L.A)


Base.:*(L::AffineOperator, u::AbstractVector) = L.A * u + L.b
Base.:\(L::AffineOperator, u::AbstractVector) = L.A \ (u - L.b)

function LinearAlgebra.mul!(v::AbstractVector, L::AffineOperator, u::AbstractVector)
    mul!(v, L.A, u)
    axpy!(true, L.b, v)
end

function LinearAlgebra.mul!(v::AbstractVector, L::AffineOperator, u::AbstractVector, α, β)
    mul!(v, L.A, u, α, β)
    axpy!(α, L.b, v)
end

function LinearAlgebra.ldiv!(v::AbstractVector, L::AffineOperator, u::AbstractVector)
    copy!(v, u)
    ldiv!(L, v)
end

function LinearAlgebra.ldiv!(L::AffineOperator, u::AbstractVector)
    axpy!(-true, L.b, u)
    ldiv!(L.A, u)
end

"""
    Matrix free operators (given by a function)
"""
struct FunctionOperator{isinplace,T,F,Fa,Fi,Fai,Tr,P,Tt,C} <: AbstractSciMLOperator{T}
    """ Function with signature op(u, p, t) and (if isinplace) op(du, u, p, t) """
    op::F
    """ Adjoint operator"""
    op_adjoint::Fa
    """ Inverse operator"""
    op_inverse::Fi
    """ Adjoint inverse operator"""
    op_adjoint_inverse::Fai
    """ Traits """
    traits::Tr
    """ Parameters """
    p::P
    """ Time """
    t::Tt
    """ Is cache set? """
    isset::Bool
    """ Cache """
    cache::C

    function FunctionOperator(op,
                              op_adjoint,
                              op_inverse,
                              op_adjoint_inverse,
                              traits,
                              p,
                              t,
                              isset,
                              cache
                             )

        iip = traits.isinplace
        T   = traits.T

        isset = cache !== nothing

        new{iip,
            T,
            typeof(op),
            typeof(op_adjoint),
            typeof(op_inverse),
            typeof(op_adjoint_inverse),
            typeof(traits),
            typeof(p),
            typeof(t),
            typeof(cache),
           }(
             op,
             op_adjoint,
             op_inverse,
             op_adjoint_inverse,
             traits,
             p,
             t,
             isset,
             cache,
            )
    end
end

function FunctionOperator(op;

                          # necessary
                          isinplace=nothing,
                          T=nothing,
                          size=nothing,

                          # optional
                          op_adjoint=nothing,
                          op_inverse=nothing,
                          op_adjoint_inverse=nothing,

                          p=nothing,
                          t=nothing,

                          cache=nothing,

                          # traits
                          opnorm=nothing,
                          issymmetric=false,
                          ishermitian=false,
                          isposdef=false,
                         )

    isinplace isa Nothing  && @error "Please provide a funciton signature
    by specifying `isinplace` as either `true`, or `false`.
    If `isinplace = false`, the signature is `op(u, p, t)`,
    and if `isinplace = true`, the signature is `op(du, u, p, t)`.
    Further, it is assumed that the function call would be nonallocating
    when called in-place"
    T isa Nothing  && @error "Please provide a Number type for the Operator"
    size isa Nothing  && @error "Please provide a size (m, n)"

    isreal = T <: Real
    adjointable = ishermitian | (isreal & issymmetric)
    invertible  = !(op_inverse isa Nothing)

    if adjointable & (op_adjoint isa Nothing) 
        op_adjoint = op
    end

    if invertible & (op_adjoint_inverse isa Nothing)
        op_adjoint_inverse = op_inverse
    end

    t = t isa Nothing ? zero(T) : t

    traits = (;
              opnorm = opnorm,
              issymmetric = issymmetric,
              ishermitian = ishermitian,
              isposdef = isposdef,

              isinplace = isinplace,
              T = T,
              size = size,
             )

    isset = cache !== nothing

    FunctionOperator(
                     op,
                     op_adjoint,
                     op_inverse,
                     op_adjoint_inverse,
                     traits,
                     p,
                     t,
                     isset,
                     cache,
                    )
end

function update_coefficients!(L::FunctionOperator, u, p, t)
    @set! L.p = p
    @set! L.t = t
    L
end

Base.size(L::FunctionOperator) = L.traits.size
function Base.adjoint(L::FunctionOperator)

    if ishermitian(L) | (isreal(L) & issymmetric(L))
        return L
    end

    if !(has_adjoint(L))
        return AdjointedOperator(L)
    end

    op = L.op_adjoint
    op_adjoint = L.op

    op_inverse = L.op_adjoint_inverse
    op_adjoint_inverse = L.op_inverse

    traits = (L.traits[1:end-1]..., size=reverse(size(L)))

    p = L.p
    t = L.t

    cache = issquare(L) ? cache : nothing
    isset = cache !== nothing


    FuncitonOperator(op,
                     op_adjoint,
                     op_inverse,
                     op_adjoint_inverse,
                     traits,
                     p,
                     t,
                     isset,
                     cache
                    )
end

function LinearAlgebra.opnorm(L::FunctionOperator, p)
  L.traits.opnorm === nothing && error("""
    M.opnorm is nothing, please define opnorm as a function that takes one
    argument. E.g., `(p::Real) -> p == Inf ? 100 : error("only Inf norm is
    defined")`
  """)
  opn = L.opnorm
  return opn isa Number ? opn : M.opnorm(p)
end
LinearAlgebra.issymmetric(L::FunctionOperator) = L.traits.issymmetric
LinearAlgebra.ishermitian(L::FunctionOperator) = L.traits.ishermitian
LinearAlgebra.isposdef(L::FunctionOperator) = L.traits.isposdef

getops(::FunctionOperator) = ()
has_adjoint(L::FunctionOperator) = !(L.op_adjoint isa Nothing)
has_mul(L::FunctionOperator{iip}) where{iip} = !iip
has_mul!(L::FunctionOperator{iip}) where{iip} = iip
has_ldiv(L::FunctionOperator{iip}) where{iip} = !iip & !(L.op_inverse isa Nothing)
has_ldiv!(L::FunctionOperator{iip}) where{iip} = iip & !(L.op_inverse isa Nothing)

# operator application
Base.:*(L::FunctionOperator, u::AbstractVector) = L.op(u, L.p, L.t)
Base.:\(L::FunctionOperator, u::AbstractVector) = L.op_inverse(u, L.p, L.t)

function cache_self(L::FunctionOperator, u::AbstractVector)
    @set! L.cache = similar(u)
    L
end

function LinearAlgebra.mul!(v::AbstractVector, L::FunctionOperator, u::AbstractVector)
    L.op(v, u, L.p, L.t)
end

function LinearAlgebra.mul!(v::AbstractVector, L::FunctionOperator, u::AbstractVector, α, β)
    @assert L.isset "set up cache by calling cache_operator($L, $u)"
    copy!(L.cache, v)
    mul!(v, L, u)
    lmul!(α, v)
    axpy!(β, L.cache, v)
end

function LinearAlgebra.ldiv!(v::AbstractVector, L::FunctionOperator, u::AbstractVector)
    L.op_inverse(v, u, L.p, L.t)
end

function LinearAlgebra.ldiv!(L::FunctionOperator, u::AbstractVector)
    @assert L.isset "set up cache by calling cache_operator($L, $u)"
    copy!(L.cache, u)
    ldiv!(u, L, L.cache)
end

"""
    Lazy Tensor Product Operator

    TensorProductOperator(A, B) = A ⊗ B

    (A ⊗ B)(u) = vec(B * U * transpose(A))

    where U is a lazy representation of the vector u as
    a matrix with the appropriate size.
"""
struct TensorProductOperator{T,O,I,C} <: AbstractSciMLOperator{T}
    outer::O
    inner::I

    cache::C
    isset::Bool

    function TensorProductOperator(out, in, cache, isset)
        T = promote_type(eltype.((out, in))...)
        isset = cache !== nothing
        new{T,
            typeof(out),
            typeof(in),
            typeof(cache)
           }(
             out, in, cache, isset
            )
    end
end

function TensorProductOperator(out, in; cache = nothing)
    isset = cache !== nothing
    TensorProductOperator(out, in, cache, isset)
end

# constructors
TensorProductOperator(op::AbstractSciMLOperator) = op
TensorProductOperator(op::AbstractMatrix) = MatrixOperator(op)
TensorProductOperator(ops...) = reduce(TensorProductOperator, ops)

# overload ⊗ (\otimes)
⊗(ops::Union{AbstractMatrix,AbstractSciMLOperator}...) = TensorProductOperator(ops...)

# convert to matrix
Base.kron(ops::AbstractSciMLOperator...) = kron(convert.(AbstractMatrix, ops)...)

function Base.convert(::Type{AbstractMatrix}, L::TensorProductOperator)
    kron(convert(AbstractMatrix, L.outer), convert(AbstractMatrix, L.inner))
end

function SparseArrays.sparse(L::TensorProductOperator)
    kron(sparse(L.outer), sparse(L.inner))
end

#LinearAlgebra.opnorm(L::TensorProductOperator) = prod(opnorm, L.ops)

Base.size(L::TensorProductOperator) = size(L.inner) .* size(L.outer)

for op in (
           :adjoint,
           :transpose,
          )
    @eval function Base.$op(L::TensorProductOperator)
        TensorProductOperator(
                              $op(L.outer),
                              $op(L.inner);
                              cache = issquare(L.inner) ? L.cache : nothing
                             )
    end
end

getops(L::TensorProductOperator) = (L.outer, L.inner)
islinear(L::TensorProductOperator) = islinear(L.outer) & islinear(L.inner)
Base.iszero(L::TensorProductOperator) = iszero(L.outer) | iszero(L.inner)
has_adjoint(L::TensorProductOperator) = has_adjoint(L.outer) & has_adjoint(L.inner)
has_mul!(L::TensorProductOperator) = has_mul!(L.outer) & has_mul!(L.inner)
has_ldiv(L::TensorProductOperator) = has_ldiv(L.outer) & has_ldiv(L.inner)
has_ldiv!(L::TensorProductOperator) = has_ldiv!(L.outer) & has_ldiv!(L.inner)

# operator application
function Base.:*(L::TensorProductOperator, u::AbstractVector)
    sz = (size(L.inner, 2), size(L.outer, 2))
    U  = _reshape(u, sz)

    C = (L.inner * U)
    V = transpose(L.outer * transpose(C))

    v = _vec(V)
end

function Base.:\(L::TensorProductOperator, u::AbstractVector)
    sz = (size(L.inner, 2), size(L.outer, 2))
    U  = _reshape(u, sz)

    C = L.inner \ U
    V = transpose(L.outer \ transpose(C))

    _vec(V)
end

function cache_self(L::TensorProductOperator, u::AbstractVector)
    sz = (size(L.inner, 2), size(L.outer, 2))
    U  = _reshape(u, sz)
    cache = L.inner * U

    @set! L.cache = cache
    L
end

function cache_internals(L::TensorProductOperator, u::AbstractVector)
    if !(L.isset)
        L = cache_self(L, u)
    end

    sz = (size(L.inner, 2), size(L.outer, 2))
    U  = _reshape(u, sz)

    uinner = U
    uouter = transpose(L.cache)

    @set! L.inner = cache_operator(L.inner, uinner)
    @set! L.outer = cache_operator(L.outer, uouter)
    L
end

function LinearAlgebra.mul!(v::AbstractVector, L::TensorProductOperator, u::AbstractVector)
    @assert L.isset "cache needs to be set up to use LinearAlgebra.mul!"

    szU = (size(L.inner, 2), size(L.outer, 2)) # in
    szV = (size(L.inner, 1), size(L.outer, 1)) # out

    U = _reshape(u, szU)
    V = _reshape(v, szV)

    """
        v .= kron(B, A) * u
        V .= A * U * B'
    """

    # C .= A * U
    mul!(L.cache, L.inner, U)
    # V .= U * B'
    mul!(V, L.cache, transpose(L.outer))

    v
end

function LinearAlgebra.mul!(v::AbstractVector, L::TensorProductOperator, u::AbstractVector, α, β)
    @assert L.isset "cache needs to be set up to use LinearAlgebra.mul!"

    szU = (size(L.inner, 2), size(L.outer, 2)) # in
    szV = (size(L.inner, 1), size(L.outer, 1)) # out

    U = _reshape(u, szU)
    V = _reshape(v, szV)

    """
        v .= α * kron(B, A) * u + β * v
        V .= α * (A * U * B') + β * v
    """

    # C .= A * U
    mul!(L.cache, L.inner, U)
    # V = α(C * B') + β(V)"""
    mul!(V, L.cache, transpose(L.outer), α, β)

    v
end

function LinearAlgebra.ldiv!(v::AbstractVector, L::TensorProductOperator, u::AbstractVector)
    @assert L.isset "cache needs to be set up to use LinearAlgebra.mul!"

    szU = (size(L.inner, 2), size(L.outer, 2)) # in
    szV = (size(L.inner, 1), size(L.outer, 1)) # out

    U = _reshape(u, szU)
    V = _reshape(v, szV)

    """
        v .= kron(B, A) ldiv u
        V .= (A ldiv U) / B'
    """

    # C .= A \ U
    ldiv!(L.cache, L.inner, U)
    # V .= C / B' <===> V' .= B \ C'
    ldiv!(transpose(V), L.outer, transpose(L.cache))

    v
end

function LinearAlgebra.ldiv!(L::TensorProductOperator, u::AbstractVector)
    @assert L.isset "cache needs to be set up to use LinearAlgebra.mul!"

    sz = (size(L.inner, 2), size(L.outer, 2))
    U  = _reshape(u, sz)

    """
        u .= kron(B, A) ldiv u
        U .= (A ldiv U) / B'
    """

    # U .= A \ U
    ldiv!(L.inner, U)
    # U .= U / B' <===> U' .= B \ U'
    ldiv!(L.outer, transpose(U))

    u
end
#