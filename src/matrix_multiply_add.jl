# import LinearAlgebra.MulAddMul

abstract type MulAddMul{TA,TB} end

struct AlphaBeta{TA,TB} <: MulAddMul{TA,TB}
    α::TA
    β::TB
end
@inline alpha(ab::AlphaBeta) = ab.α
@inline beta(ab::AlphaBeta) = ab.β

struct NoMulAdd{TA,TB} <: MulAddMul{TA,TB} end
@inline alpha(ma::NoMulAdd{TA,TB}) where {TA,TB} = one(TA)
@inline beta(ma::NoMulAdd{TA,TB}) where {TA,TB} = zero(TB)

"""
    StaticMatMulLike

Static wrappers used for multiplication dispatch.
"""
const StaticMatMulLike{s1, s2, T} = Union{
    StaticMatrix{s1, s2, T},
    Symmetric{T, <:StaticMatrix{s1, s2, T}},
    Hermitian{T, <:StaticMatrix{s1, s2, T}},
    LowerTriangular{T, <:StaticMatrix{s1, s2, T}},
    UpperTriangular{T, <:StaticMatrix{s1, s2, T}},
    UnitLowerTriangular{T, <:StaticMatrix{s1, s2, T}},
    UnitUpperTriangular{T, <:StaticMatrix{s1, s2, T}},
    Adjoint{T, <:StaticMatrix{s1, s2, T}},
    Transpose{T, <:StaticMatrix{s1, s2, T}},
    SDiagonal{s1, T}}


""" Size that stores whether a Matrix is a Transpose
Useful when selecting multiplication methods, and avoiding allocations when dealing with
the `Transpose` type by passing around the original matrix.
Should pair with `parent`.
"""
struct TSize{S,T}
    function TSize{S,T}() where {S,T}
        new{S::Tuple{Vararg{StaticDimension}},T::Symbol}()
    end
end
TSize(A::Type{<:StaticArrayLike}) = TSize{size(A), gen_by_access(identity, A)}()
TSize(A::StaticArrayLike) = TSize(typeof(A))
TSize(S::Size{s}, T=:any) where s = TSize{s,T}()
TSize(s::Number) = TSize(Size(s))
istranspose(::TSize{<:Any,T}) where T = (T === :transpose)
size(::TSize{S}) where S = S
Size(::TSize{S}) where S = Size{S}()
access_type(::TSize{<:Any,T}) where T = T
Base.transpose(::TSize{S,:transpose}) where {S,T} = TSize{reverse(S),:any}()
Base.transpose(::TSize{S,:any}) where {S,T} = TSize{reverse(S),:transpose}()

# Get the parent of transposed arrays, or the array itself if it has no parent
# Different from Base.parent because we only want to get rid of Transpose and Adjoint
# The two last methods can't be combined into one for StaticVecOrMat because then dispatch
# goes wrong for SizedArray
@inline mul_parent(A::Union{StaticMatMulLike, Adjoint{<:Any,<:StaticVector}, Transpose{<:Any,<:StaticVector}}) = Base.parent(A)
@inline mul_parent(A::StaticMatrix) = A
@inline mul_parent(A::StaticVector) = A

# 5-argument matrix multiplication
#    To avoid allocations, strip away Transpose type and store tranpose info in Size
@inline LinearAlgebra.mul!(dest::StaticVecOrMatLike, A::StaticVecOrMatLike, B::StaticVecOrMatLike,
    α::Real, β::Real) = _mul!(TSize(dest), mul_parent(dest), Size(A), Size(B), A, B,
    AlphaBeta(α,β))

@inline function LinearAlgebra.mul!(dest::StaticVecOrMatLike{TDest}, A::StaticVecOrMatLike{TA},
        B::StaticVecOrMatLike{TB}) where {TDest,TA,TB}
    TMul = promote_op(matprod, TA, TB)
    return _mul!(TSize(dest), mul_parent(dest), Size(A), Size(B), A, B, NoMulAdd{TMul, TDest}())
end


"Calculate the product of the dimensions being multiplied. Useful as a heuristic for unrolling."
@inline multiplied_dimension(A::Type{<:StaticVecOrMatLike}, B::Type{<:StaticVecOrMatLike}) =
    prod(size(A)) * size(B,2)

"Validate the dimensions of a matrix multiplication, including matrix-vector products"
function check_dims(::Size{sc}, ::Size{sa}, ::Size{sb}) where {sa,sb,sc}
    if sb[1] != sa[2] || sc[1] != sa[1]
        return false
    elseif length(sc) == 2 || length(sb) == 2
        sc2 = length(sc) == 1 ? 1 : sc[2]
        sb2 = length(sb) == 1 ? 1 : sb[2]
        if sc2 != sb2
            return false
        end
    end
    return true
end

""" Combine left and right sides of an assignment expression, short-cutting
        lhs = α * rhs + β * lhs,
    element-wise.
If α = 1, the multiplication by α is removed. If β = 0, the second rhs term is removed.
"""
function _muladd_expr(lhs::Array{Expr}, rhs::Array{Expr}, ::Type{<:AlphaBeta})
    @assert length(lhs) == length(rhs)
    n = length(rhs)
    rhs = [:(α * $(expr)) for expr in rhs]
    rhs = [:($(lhs[k]) * β + $(rhs[k])) for k = 1:n]
    exprs = [:($(lhs[k]) = $(rhs[k])) for k = 1:n]
    _assign(lhs, rhs)
    return exprs
end

@inline _muladd_expr(lhs::Array{Expr}, rhs::Array{Expr}, ::Type{<:MulAddMul}) = _assign(lhs, rhs)

@inline function _assign(lhs::Array{Expr}, rhs::Array{Expr})
    @assert length(lhs) == length(rhs)
    [:($(lhs[k]) = $(rhs[k])) for k = 1:length(lhs)]
end

"Obtain an expression for the linear index of var[k,j], taking transposes into account"
function _lind(var::Symbol, A::Type{TSize{sa,tA}}, k::Int, j::Int) where {sa,tA}
    ula = uplo_access(sa, var, k, j, tA)
    if ula.head == :call && ula.args[1] == :transpose
        # TODO: can this be properly fixed at all?
        return ula.args[2]
    end
    return ula
end



# Matrix-vector multiplication
@generated function _mul!(Sc::TSize{sc}, c::StaticVecOrMatLike, Sa::Size{sa}, Sb::Size{sb},
        wrapped_a::StaticMatMulLike{<:Any, <:Any, Ta}, b::StaticVector{<:Any, Tb}, _add::MulAddMul,
        ::Val{col}=Val(1)) where {sa, sb, sc, col, Ta, Tb}
    if sa[2] != sb[1] || sc[1] != sa[1]
        throw(DimensionMismatch("Tried to multiply arrays of size $sa and $sb and assign to array of size $sc"))
    end

    if sa[2] != 0
        assign_expr = gen_by_access(wrapped_a) do access_a
            lhs = [_lind(:c,Sc,k,col) for k = 1:sa[1]]
            ab = [combine_products([:($(uplo_access(sa, :a, k, j, access_a)) * b[$j]) for j = 1:sa[2]]) for k = 1:sa[1]]
            exprs = _muladd_expr(lhs, ab, _add)

            return :(@inbounds $(Expr(:block, exprs...)))
        end
    else
        exprs = [:(c[$k] = zero(eltype(c))) for k = 1:sa[1]]
        assign_expr = :(@inbounds $(Expr(:block, exprs...)))
    end

    return quote
        # @_inline_meta
        α = alpha(_add)
        β = beta(_add)
        a = mul_parent(wrapped_a)
        $assign_expr
        return c
    end
end

# Outer product
@generated function _mul!(::TSize{sc}, c::StaticMatrix, tsa::Size{sa}, tsb::Size{sb},
        a::StaticVector, b::Union{Transpose{<:Any, <:StaticVector}, Adjoint{<:Any, <:StaticVector}}, _add::MulAddMul) where {sa, sb, sc}
    if sc[1] != sa[1] || sc[2] != sb[2]
        throw(DimensionMismatch("Tried to multiply arrays of size $sa and $sb and assign to array of size $sc"))
    end

    conjugate_b = b <: Adjoint

    lhs = [:(c[$(LinearIndices(sc)[i,j])]) for i = 1:sa[1], j = 1:sb[2]]
    if conjugate_b
        ab = [:(a[$i] * adjoint(b[$j])) for i = 1:sa[1], j = 1:sb[2]]
    else
        ab = [:(a[$i] * transpose(b[$j])) for i = 1:sa[1], j = 1:sb[2]]
    end
    
    exprs = _muladd_expr(lhs, ab, _add)

    return quote
        @_inline_meta
        α = alpha(_add)
        β = beta(_add)
        @inbounds $(Expr(:block, exprs...))
        return c
    end
end

# Matrix-matrix multiplication
@generated function _mul!(Sc::TSize{sc}, c::StaticMatMulLike,
        Sa::Size{sa}, Sb::Size{sb},
        a::StaticMatMulLike, b::StaticMatMulLike,
        _add::MulAddMul) where {sa, sb, sc}
    Ta,Tb,Tc = eltype(a), eltype(b), eltype(c)
    can_blas = Tc == Ta && Tc == Tb && Tc <: BlasFloat && a <: Union{StaticMatrix,Transpose} && b <: Union{StaticMatrix,Transpose}

    mult_dim = multiplied_dimension(a,b)
    a_tri_mul = a <: LinearAlgebra.AbstractTriangular ? 2 : 1
    b_tri_mul = b <: LinearAlgebra.AbstractTriangular ? 2 : 1
    ab_tri_mul = (a == 2 && b == 2) ? 2 : 1
    if mult_dim < 4*4*4*a_tri_mul*b_tri_mul*ab_tri_mul || a <: Diagonal || b <: Diagonal
        return quote
            @_inline_meta
            muladd_unrolled_all!(Sc, c, Sa, Sb, a, b, _add)
            return c
        end
    elseif mult_dim < 14*14*14 # Something seems broken for this one with large matrices (becomes allocating)
        return quote
            @_inline_meta
            muladd_unrolled_chunks!(Sc, c, Sa, Sb, a, b, _add)
            return c
        end
    else
        if can_blas
            return quote
                @_inline_meta
                mul_blas!(Sc, c, TSize(a), TSize(b), mul_parent(a), mul_parent(b), _add)
                return c
            end
        else
            return quote
                @_inline_meta
                muladd_unrolled_chunks!(Sc, c, Sa, Sb, a, b, _add)
                return c
            end
        end
    end
end


@generated function muladd_unrolled_all!(Sc::TSize{sc}, wrapped_c::StaticMatMulLike, Sa::Size{sa}, Sb::Size{sb},
        wrapped_a::StaticMatMulLike{<:Any,<:Any,Ta}, wrapped_b::StaticMatMulLike{<:Any,<:Any,Tb}, _add::MulAddMul) where {sa, sb, sc, Ta, Tb}
    if !check_dims(Size(sc),Size(sa),Size(sb))
        throw(DimensionMismatch("Tried to multiply arrays of size $sa and $sb and assign to array of size $sc"))
    end

    if sa[2] != 0
        lhs = [_lind(:c, Sc, k1, k2) for k1 = 1:sa[1], k2 = 1:sb[2]]

        assign_expr = gen_by_access(wrapped_a, wrapped_b) do access_a, access_b

            ab = [combine_products([:($(uplo_access(sa, :a, k1, j, access_a)) * $(uplo_access(sb, :b, j, k2, access_b))) for j = 1:sa[2]]
                ) for k1 = 1:sa[1], k2 = 1:sb[2]]

            exprs = _muladd_expr(lhs, ab, _add)
            return :(@inbounds $(Expr(:block, exprs...)))
        end
    else
        exprs = [:(c[$k] = zero(eltype(c))) for k = 1:sc[1]*sc[2]]
        assign_expr = :(@inbounds $(Expr(:block, exprs...)))
    end

    return quote
        @_inline_meta
        # α = _add.alpha
        # β = _add.beta
        α = alpha(_add)
        β = beta(_add)
        c = mul_parent(wrapped_c)
        a = mul_parent(wrapped_a)
        b = mul_parent(wrapped_b)
        T = promote_op(matprod,Ta,Tb)
        $assign_expr
        return c
    end
end


@generated function muladd_unrolled_chunks!(Sc::TSize{sc}, wrapped_c::StaticMatMulLike, ::Size{sa}, Sb::Size{sb},
        wrapped_a::StaticMatMulLike{<:Any,<:Any,Ta}, wrapped_b::StaticMatMulLike{<:Any,<:Any,Tb}, _add::MulAddMul) where {sa, sb, sc, Ta, Tb}
    if sb[1] != sa[2] || sa[1] != sc[1] || sb[2] != sc[2]
        throw(DimensionMismatch("Tried to multiply arrays of size $sa and $sb and assign to array of size $sc"))
    end

    # This will not work for Symmetric and Hermitian wrappers of c
    lhs = [_lind(:c, Sc, k1, k2) for k1 = 1:sa[1], k2 = 1:sb[2]]

    #vect_exprs = [:($(Symbol("tmp_$k2")) = partly_unrolled_multiply(A, B[:, $k2])) for k2 = 1:sB[2]]

    # Do a custom b[:, k2] to return a SVector (an isbitstype type) rather than a mutable type. Avoids allocation == faster
    tmp_type = SVector{sb[1], eltype(wrapped_c)}

    assign_expr = gen_by_access(wrapped_a, wrapped_b) do access_a, access_b
        vect_exprs = [:($(Symbol("tmp_$k2")) = partly_unrolled_multiply($(Size{sa}()), $(Size{(sb[1],)}()),
            a, $(Expr(:call, tmp_type, [uplo_access(sb, :b, i, k2, access_b) for i = 1:sb[1]]...)), $(Val(access_a)))) for k2 = 1:sb[2]]

        # exprs = [:(c[$(LinearIndices(sc)[k1, k2])] = $(Symbol("tmp_$k2"))[$k1]) for k1 = 1:sa[1], k2 = 1:sb[2]]
        rhs = [:($(Symbol("tmp_$k2"))[$k1]) for k1 = 1:sa[1], k2 = 1:sb[2]]
        exprs = _muladd_expr(lhs, rhs, _add)

        return quote
            @inbounds $(Expr(:block, vect_exprs...))
            @inbounds $(Expr(:block, exprs...))
        end
    end
    
    return quote
        @_inline_meta
        α = alpha(_add)
        β = beta(_add)
        c = mul_parent(wrapped_c)
        a = mul_parent(wrapped_a)
        b = mul_parent(wrapped_b)
        $assign_expr
    end
end

# @inline partly_unrolled_multiply(Sa::Size, Sb::Size, a::StaticMatrix, b::StaticArray) where {sa, sb, Ta, Tb} =
#     partly_unrolled_multiply(TSize(Sa), TSize(Sb), a, b)
@generated function partly_unrolled_multiply(Sa::Size{sa}, ::Size{sb}, a::StaticMatMulLike{<:Any, <:Any, Ta}, b::StaticArray{<:Tuple, Tb}, ::Val{access_a}) where {sa, sb, Ta, Tb, access_a}
    if sa[2] != sb[1]
        throw(DimensionMismatch("Tried to multiply arrays of size $sa and $sb"))
    end

    if sa[2] != 0
        exprs = [combine_products([:($(uplo_access(sa, :a, k, j, access_a))*b[$j]) for j = 1:sa[2]]) for k = 1:sa[1]]
    else
        exprs = [:(zero(promote_op(matprod,Ta,Tb))) for k = 1:sa[1]]
    end

    return quote
        $(Expr(:meta,:noinline))
        @inbounds return SVector(tuple($(exprs...)))
    end
end

@inline _get_raw_data(A::SizedArray) = A.data
@inline _get_raw_data(A::StaticArray) = A
# we need something heap-allocated to make sure BLAS calls are safe
@inline _get_raw_data(A::SArray) = MArray(A)

function mul_blas!(::TSize{<:Any,:any}, c::StaticMatrix,
        Sa::Union{TSize{<:Any,:any}, TSize{<:Any,:transpose}}, Sb::Union{TSize{<:Any,:any}, TSize{<:Any,:transpose}},
        a::StaticMatrix, b::StaticMatrix, _add::MulAddMul)
    mat_char(s) = istranspose(s) ? 'T' : 'N'
    T = eltype(a)
    A = _get_raw_data(a)
    B = _get_raw_data(b)
    C = _get_raw_data(c)
    BLAS.gemm!(mat_char(Sa), mat_char(Sb), T(alpha(_add)), A, B, T(beta(_add)), C)
end

# if C is transposed, transpose the entire expression
@inline mul_blas!(Sc::TSize{<:Any,:transpose}, c::StaticMatrix, Sa::TSize, Sb::TSize,
        a::StaticMatrix, b::StaticMatrix, _add::MulAddMul) =
    mul_blas!(transpose(Sc), c, transpose(Sb), transpose(Sa), b, a, _add)
