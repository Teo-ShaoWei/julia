# This file is a part of Julia. License is MIT: http://julialang.org/license

module Broadcast

using Base.Cartesian
using Base: promote_eltype_op, linearindices, tail, OneTo, to_shape,
            _msk_end, unsafe_bitgetindex, bitcache_chunks, bitcache_size, dumpbitcache,
            nullable_returntype, null_safe_eltype_op, hasvalue
import Base: broadcast, broadcast!
export broadcast_getindex, broadcast_setindex!, dotview

typealias ScalarType Union{Type{Any}, Type{Nullable}}

## Broadcasting utilities ##
# fallbacks for some special cases
@inline broadcast(f, x::Number...) = f(x...)
@inline broadcast{N}(f, t::NTuple{N}, ts::Vararg{NTuple{N}}) = map(f, t, ts...)

# special cases for "X .= ..." (broadcast!) assignments
broadcast!(::typeof(identity), X::AbstractArray, x::Number) = fill!(X, x)
broadcast!(f, X::AbstractArray, x::Number...) = (@inbounds for I in eachindex(X); X[I] = f(x...); end; X)
function broadcast!{T,S,N}(::typeof(identity), x::AbstractArray{T,N}, y::AbstractArray{S,N})
    check_broadcast_shape(broadcast_indices(x), broadcast_indices(y))
    copy!(x, y)
end

# logic for deciding the resulting container type
containertype(x) = containertype(typeof(x))
containertype(::Type) = Any
containertype{T<:Ptr}(::Type{T}) = Any
containertype{T<:Tuple}(::Type{T}) = Tuple
containertype{T<:Ref}(::Type{T}) = Array
containertype{T<:AbstractArray}(::Type{T}) = Array
containertype{T<:Nullable}(::Type{T}) = Nullable
containertype(ct1, ct2) = promote_containertype(containertype(ct1), containertype(ct2))
@inline containertype(ct1, ct2, cts...) = promote_containertype(containertype(ct1), containertype(ct2, cts...))

promote_containertype(::Type{Array}, ::Type{Array}) = Array
promote_containertype(::Type{Array}, ct) = Array
promote_containertype(ct, ::Type{Array}) = Array
promote_containertype(::Type{Tuple}, ::ScalarType) = Tuple
promote_containertype(::ScalarType, ::Type{Tuple}) = Tuple
promote_containertype(::Type{Any}, ::Type{Nullable}) = Nullable
promote_containertype(::Type{Nullable}, ::Type{Any}) = Nullable
promote_containertype{T}(::Type{T}, ::Type{T}) = T

## Calculate the broadcast indices of the arguments, or error if incompatible
# array inputs
broadcast_indices() = ()
broadcast_indices(A) = broadcast_indices(containertype(A), A)
broadcast_indices(::ScalarType, A) = ()
broadcast_indices(::Type{Tuple}, A) = (OneTo(length(A)),)
broadcast_indices(::Type{Array}, A::Ref) = ()
broadcast_indices(::Type{Array}, A) = indices(A)
@inline broadcast_indices(A, B...) = broadcast_shape((), broadcast_indices(A), map(broadcast_indices, B)...)
# shape (i.e., tuple-of-indices) inputs
broadcast_shape(shape::Tuple) = shape
@inline broadcast_shape(shape::Tuple, shape1::Tuple, shapes::Tuple...) = broadcast_shape(_bcs((), shape, shape1), shapes...)
# _bcs consolidates two shapes into a single output shape
_bcs(out, ::Tuple{}, ::Tuple{}) = out
@inline _bcs(out, ::Tuple{}, newshape) = _bcs((out..., newshape[1]), (), tail(newshape))
@inline _bcs(out, shape, ::Tuple{}) = _bcs((out..., shape[1]), tail(shape), ())
@inline function _bcs(out, shape, newshape)
    newout = _bcs1(shape[1], newshape[1])
    _bcs((out..., newout), tail(shape), tail(newshape))
end
# _bcs1 handles the logic for a single dimension
_bcs1(a::Integer, b::Integer) = a == 1 ? b : (b == 1 ? a : (a == b ? a : throw(DimensionMismatch("arrays could not be broadcast to a common size"))))
_bcs1(a::Integer, b) = a == 1 ? b : (first(b) == 1 && last(b) == a ? b : throw(DimensionMismatch("arrays could not be broadcast to a common size")))
_bcs1(a, b::Integer) = _bcs1(b, a)
_bcs1(a, b) = _bcsm(b, a) ? b : (_bcsm(a, b) ? a : throw(DimensionMismatch("arrays could not be broadcast to a common size")))
# _bcsm tests whether the second index is consistent with the first
_bcsm(a, b) = a == b || length(b) == 1
_bcsm(a, b::Number) = b == 1
_bcsm(a::Number, b::Number) = a == b || b == 1

## Check that all arguments are broadcast compatible with shape
# comparing one input against a shape
check_broadcast_shape(shp) = nothing
check_broadcast_shape(shp, ::Tuple{}) = nothing
check_broadcast_shape(::Tuple{}, ::Tuple{}) = nothing
check_broadcast_shape(::Tuple{}, Ashp::Tuple) = throw(DimensionMismatch("cannot broadcast array to have fewer dimensions"))
function check_broadcast_shape(shp, Ashp::Tuple)
    _bcsm(shp[1], Ashp[1]) || throw(DimensionMismatch("array could not be broadcast to match destination"))
    check_broadcast_shape(tail(shp), tail(Ashp))
end
check_broadcast_indices(shp, A) = check_broadcast_shape(shp, broadcast_indices(A))
# comparing many inputs
@inline function check_broadcast_indices(shp, A, As...)
    check_broadcast_indices(shp, A)
    check_broadcast_indices(shp, As...)
end

## Indexing manipulations

# newindex(I, keep, Idefault) replaces a CartesianIndex `I` with something that
# is appropriate for a particular broadcast array/scalar. `keep` is a
# NTuple{N,Bool}, where keep[d] == true means that one should preserve
# I[d]; if false, replace it with Idefault[d].
@inline newindex(I::CartesianIndex, keep, Idefault) = CartesianIndex(_newindex(I.I, keep, Idefault))
@inline _newindex(I, keep, Idefault) =
    (ifelse(keep[1], I[1], Idefault[1]), _newindex(tail(I), tail(keep), tail(Idefault))...)
@inline _newindex(I, keep::Tuple{}, Idefault) = ()  # truncate if keep is shorter than I

# newindexer(shape, A) generates `keep` and `Idefault` (for use by
# `newindex` above) for a particular array `A`, given the
# broadcast_indices `shape`
# `keep` is equivalent to map(==, indices(A), shape) (but see #17126)
@inline newindexer(shape, A) = shapeindexer(shape, broadcast_indices(A))
@inline shapeindexer(shape, indsA::Tuple{}) = (), ()
@inline function shapeindexer(shape, indsA::Tuple)
    ind1 = indsA[1]
    keep, Idefault = shapeindexer(tail(shape), tail(indsA))
    (shape[1] == ind1, keep...), (first(ind1), Idefault...)
end

# Equivalent to map(x->newindexer(shape, x), As) (but see #17126)
map_newindexer(shape, ::Tuple{}) = (), ()
@inline function map_newindexer(shape, As)
    A1 = As[1]
    keeps, Idefaults = map_newindexer(shape, tail(As))
    keep, Idefault = newindexer(shape, A1)
    (keep, keeps...), (Idefault, Idefaults...)
end

Base.@propagate_inbounds _broadcast_getindex(A, I) = _broadcast_getindex(containertype(A), A, I)
Base.@propagate_inbounds _broadcast_getindex(::Type{Array}, A::Ref, I) = A[]
Base.@propagate_inbounds _broadcast_getindex(::ScalarType, A, I) = A
Base.@propagate_inbounds _broadcast_getindex(::Any, A, I) = A[I]

## Broadcasting core
# nargs encodes the number of As arguments (which matches the number
# of keeps). The first two type parameters are to ensure specialization.
@generated function _broadcast!{K,ID,AT,nargs}(f, B::AbstractArray, keeps::K, Idefaults::ID, As::AT, ::Type{Val{nargs}}, iter)
    quote
        $(Expr(:meta, :inline))
        # destructure the keeps and As tuples
        @nexprs $nargs i->(A_i = As[i])
        @nexprs $nargs i->(keep_i = keeps[i])
        @nexprs $nargs i->(Idefault_i = Idefaults[i])
        @simd for I in iter
            # reverse-broadcast the indices
            @nexprs $nargs i->(I_i = newindex(I, keep_i, Idefault_i))
            # extract array values
            @nexprs $nargs i->(@inbounds val_i = _broadcast_getindex(A_i, I_i))
            # call the function and store the result
            result = @ncall $nargs f val
            @inbounds B[I] = result
        end
    end
end

# For BitArray outputs, we cache the result in a "small" Vector{Bool},
# and then copy in chunks into the output
@generated function _broadcast!{K,ID,AT,nargs}(f, B::BitArray, keeps::K, Idefaults::ID, As::AT, ::Type{Val{nargs}}, iter)
    quote
        $(Expr(:meta, :inline))
        # destructure the keeps and As tuples
        @nexprs $nargs i->(A_i = As[i])
        @nexprs $nargs i->(keep_i = keeps[i])
        @nexprs $nargs i->(Idefault_i = Idefaults[i])
        C = Vector{Bool}(bitcache_size)
        Bc = B.chunks
        ind = 1
        cind = 1
        @simd for I in iter
            # reverse-broadcast the indices
            @nexprs $nargs i->(I_i = newindex(I, keep_i, Idefault_i))
            # extract array values
            @nexprs $nargs i->(@inbounds val_i = _broadcast_getindex(A_i, I_i))
            # call the function and store the result
            @inbounds C[ind] = @ncall $nargs f val
            ind += 1
            if ind > bitcache_size
                dumpbitcache(Bc, cind, C)
                cind += bitcache_chunks
                ind = 1
            end
        end
        if ind > 1
            @inbounds C[ind:bitcache_size] = false
            dumpbitcache(Bc, cind, C)
        end
    end
end

"""
    broadcast!(f, dest, As...)

Like [`broadcast`](@ref), but store the result of
`broadcast(f, As...)` in the `dest` array.
Note that `dest` is only used to store the result, and does not supply
arguments to `f` unless it is also listed in the `As`,
as in `broadcast!(f, A, A, B)` to perform `A[:] = broadcast(f, A, B)`.
"""
@inline function broadcast!{nargs}(f, B::AbstractArray, As::Vararg{Any,nargs})
    shape = indices(B)
    check_broadcast_indices(shape, As...)
    keeps, Idefaults = map_newindexer(shape, As)
    iter = CartesianRange(shape)
    _broadcast!(f, B, keeps, Idefaults, As, Val{nargs}, iter)
    return B
end

# broadcast with computed element type
@generated function _broadcast!{K,ID,AT,nargs}(f, B::AbstractArray, keeps::K, Idefaults::ID, As::AT, ::Type{Val{nargs}}, iter, st, count)
    quote
        $(Expr(:meta, :noinline))
        # destructure the keeps and As tuples
        @nexprs $nargs i->(A_i = As[i])
        @nexprs $nargs i->(keep_i = keeps[i])
        @nexprs $nargs i->(Idefault_i = Idefaults[i])
        while !done(iter, st)
            I, st = next(iter, st)
            # reverse-broadcast the indices
            @nexprs $nargs i->(I_i = newindex(I, keep_i, Idefault_i))
            # extract array values
            @nexprs $nargs i->(@inbounds val_i = _broadcast_getindex(A_i, I_i))
            # call the function
            V = @ncall $nargs f val
            S = typeof(V)
            # store the result
            if S <: eltype(B)
                @inbounds B[I] = V
            else
                R = typejoin(eltype(B), S)
                new = similar(B, R)
                for II in Iterators.take(iter, count)
                    new[II] = B[II]
                end
                new[I] = V
                return _broadcast!(f, new, keeps, Idefaults, As, Val{nargs}, iter, st, count+1)
            end
            count += 1
        end
        return B
    end
end

# broadcast methods that dispatch on the type found by inference
function broadcast_t(f, ::Type{Any}, shape, iter, As...)
    nargs = length(As)
    keeps, Idefaults = map_newindexer(shape, As)
    st = start(iter)
    I, st = next(iter, st)
    val = f([ _broadcast_getindex(As[i], newindex(I, keeps[i], Idefaults[i])) for i=1:nargs ]...)
    B = similar(Array{typeof(val)}, shape)
    B[I] = val
    return _broadcast!(f, B, keeps, Idefaults, As, Val{nargs}, iter, st, 1)
end
@inline function broadcast_t{nargs}(f, T, shape, iter, As::Vararg{Any,nargs})
    B = similar(Array{T}, shape)
    keeps, Idefaults = map_newindexer(shape, As)
    _broadcast!(f, B, keeps, Idefaults, As, Val{nargs}, iter)
    return B
end

# default to BitArray for broadcast operations producing Bool, to save 8x space
# in the common case where this is used for logical array indexing; in
# performance-critical cases where Array{Bool} is desired, one can always
# use broadcast! instead.
function broadcast_t(f, ::Type{Bool}, shape, iter, As...)
    B = similar(BitArray, shape)
    nargs = length(As)
    keeps, Idefaults = map_newindexer(shape, As)
    _broadcast!(f, B, keeps, Idefaults, As, Val{nargs}, iter)
    return B
end

# broadcast method that uses inference to find the type, but preserves abstract
# container types when possible (used by binary elementwise operators)
@inline broadcast_elwise_op(f, As...) =
    broadcast!(f, similar(Array{promote_eltype_op(f, As...)}, broadcast_indices(As...)), As...)

ftype(f, A) = typeof(f)
ftype(f, A...) = typeof(a -> f(a...))
ftype(T::Type, A...) = Type{T}

typestuple(a) = (Base.@_pure_meta; Tuple{eltype(a)})
typestuple(T::Type) = (Base.@_pure_meta; Tuple{Type{T}})
typestuple(a, b...) = (Base.@_pure_meta; Tuple{typestuple(a).types..., typestuple(b...).types...})

ziptype(A) = typestuple(A)
ziptype(A, B) = (Base.@_pure_meta; Iterators.Zip2{typestuple(A), typestuple(B)})
@inline ziptype(A, B, C, D...) = Iterators.Zip{typestuple(A), ziptype(B, C, D...)}

_broadcast_type(f, T::Type, As...) = Base._return_type(f, typestuple(T, As...))
_broadcast_type(f, A, Bs...) = Base._default_eltype(Base.Generator{ziptype(A, Bs...), ftype(f, A, Bs...)})

# broadcast methods that dispatch on the type of the final container
@inline function broadcast_c(f, ::Type{Array}, A, Bs...)
    T = _broadcast_type(f, A, Bs...)
    shape = broadcast_indices(A, Bs...)
    iter = CartesianRange(shape)
    if isleaftype(T)
        return broadcast_t(f, T, shape, iter, A, Bs...)
    end
    if isempty(iter)
        return similar(Array{T}, shape)
    end
    return broadcast_t(f, Any, shape, iter, A, Bs...)
end
function broadcast_c(f, ::Type{Tuple}, As...)
    shape = broadcast_indices(As...)
    n = length(shape[1])
    return ntuple(k->f((_broadcast_getindex(A, k) for A in As)...), n)
end
@inline function broadcast_c(f, ::Type{Nullable}, a...)
    nonnull = all(hasvalue, a)
    S = _broadcast_type(f, a...)
    if isleaftype(S) && null_safe_eltype_op(f, a...)
        Nullable{S}(f(map(unsafe_get, a)...), nonnull)
    else
        if nonnull
            Nullable(f(map(unsafe_get, a)...))
        else
            Nullable{nullable_returntype(S)}()
        end
    end
end
@inline broadcast_c(f, ::Type{Any}, a...) = f(a...)

"""
    broadcast(f, As...)

Broadcasts the arrays, tuples, `Ref`s, nullables, and/or scalars `As` to a
container of the appropriate type and dimensions. In this context, anything
that is not a subtype of `AbstractArray`, `Ref` (except for `Ptr`s), `Tuple`,
or `Nullable` is considered a scalar. The resulting container is established by
the following rules:

 - If all the arguments are scalars, it returns a scalar.
 - If the arguments are tuples and zero or more scalars, it returns a tuple.
 - If the arguments contain at least one array or `Ref`, it returns an array
   (expanding singleton dimensions), and treats `Ref`s as 0-dimensional arrays,
   and tuples as a 1-dimensional arrays.

The following additional rule applies to `Nullable` arguments: If there is at
least one `Nullable`, and all the arguments are scalars or `Nullable`, it
returns a `Nullable` treating `Nullable`s as "containers".

A special syntax exists for broadcasting: `f.(args...)` is equivalent to
`broadcast(f, args...)`, and nested `f.(g.(args...))` calls are fused into a
single broadcast loop.

```jldoctest
julia> A = [1, 2, 3, 4, 5]
5-element Array{Int64,1}:
 1
 2
 3
 4
 5

julia> B = [1 2; 3 4; 5 6; 7 8; 9 10]
5×2 Array{Int64,2}:
 1   2
 3   4
 5   6
 7   8
 9  10

julia> broadcast(+, A, B)
5×2 Array{Int64,2}:
  2   3
  5   6
  8   9
 11  12
 14  15

julia> parse.(Int, ["1", "2"])
2-element Array{Int64,1}:
 1
 2

julia> abs.((1, -2))
(1,2)

julia> broadcast(+, 1.0, (0, -2.0))
(1.0,-1.0)

julia> broadcast(+, 1.0, (0, -2.0), Ref(1))
2-element Array{Float64,1}:
 2.0
 0.0

julia> (+).([[0,2], [1,3]], Ref{Vector{Int}}([1,-1]))
2-element Array{Array{Int64,1},1}:
 [1,1]
 [2,2]

julia> string.(("one","two","three","four"), ": ", 1:4)
4-element Array{String,1}:
 "one: 1"
 "two: 2"
 "three: 3"
 "four: 4"

julia> Nullable("X") .* "Y"
Nullable{String}("XY")

julia> broadcast(/, 1.0, Nullable(2.0))
Nullable{Float64}(0.5)

julia> (1 + im) ./ Nullable{Int}()
Nullable{Complex{Float64}}()
```
"""
@inline broadcast(f, A, Bs...) = broadcast_c(f, containertype(A, Bs...), A, Bs...)

"""
    broadcast_getindex(A, inds...)

Broadcasts the `inds` arrays to a common size like [`broadcast`](@ref)
and returns an array of the results `A[ks...]`,
where `ks` goes over the positions in the broadcast result `A`.

```jldoctest
julia> A = [1, 2, 3, 4, 5]
5-element Array{Int64,1}:
 1
 2
 3
 4
 5

julia> B = [1 2; 3 4; 5 6; 7 8; 9 10]
5×2 Array{Int64,2}:
 1   2
 3   4
 5   6
 7   8
 9  10

julia> C = broadcast(+,A,B)
5×2 Array{Int64,2}:
  2   3
  5   6
  8   9
 11  12
 14  15

julia> broadcast_getindex(C,[1,2,10])
3-element Array{Int64,1}:
  2
  5
 15
```
"""
broadcast_getindex(src::AbstractArray, I::AbstractArray...) = broadcast_getindex!(similar(Array{eltype(src)}, broadcast_indices(I...)), src, I...)
@generated function broadcast_getindex!(dest::AbstractArray, src::AbstractArray, I::AbstractArray...)
    N = length(I)
    Isplat = Expr[:(I[$d]) for d = 1:N]
    quote
        @nexprs $N d->(I_d = I[d])
        check_broadcast_indices(indices(dest), $(Isplat...))  # unnecessary if this function is never called directly
        checkbounds(src, $(Isplat...))
        @nexprs $N d->(@nexprs $N k->(Ibcast_d_k = indices(I_k, d) == OneTo(1)))
        @nloops $N i dest d->(@nexprs $N k->(j_d_k = Ibcast_d_k ? 1 : i_d)) begin
            @nexprs $N k->(@inbounds J_k = @nref $N I_k d->j_d_k)
            @inbounds (@nref $N dest i) = (@nref $N src J)
        end
        dest
    end
end

"""
    broadcast_setindex!(A, X, inds...)

Broadcasts the `X` and `inds` arrays to a common size and stores the value from each
position in `X` at the indices in `A` given by the same positions in `inds`.
"""
@generated function broadcast_setindex!(A::AbstractArray, x, I::AbstractArray...)
    N = length(I)
    Isplat = Expr[:(I[$d]) for d = 1:N]
    quote
        @nexprs $N d->(I_d = I[d])
        checkbounds(A, $(Isplat...))
        shape = broadcast_indices($(Isplat...))
        @nextract $N shape d->(length(shape) < d ? OneTo(1) : shape[d])
        @nexprs $N d->(@nexprs $N k->(Ibcast_d_k = indices(I_k, d) == 1:1))
        if !isa(x, AbstractArray)
            xA = convert(eltype(A), x)
            @nloops $N i d->shape_d d->(@nexprs $N k->(j_d_k = Ibcast_d_k ? 1 : i_d)) begin
                @nexprs $N k->(@inbounds J_k = @nref $N I_k d->j_d_k)
                @inbounds (@nref $N A J) = xA
            end
        else
            X = x
            @nexprs $N d->(shapelen_d = length(shape_d))
            @ncall $N Base.setindex_shape_check X shapelen
            Xstate = start(X)
            @inbounds @nloops $N i d->shape_d d->(@nexprs $N k->(j_d_k = Ibcast_d_k ? 1 : i_d)) begin
                @nexprs $N k->(J_k = @nref $N I_k d->j_d_k)
                x_el, Xstate = next(X, Xstate)
                (@nref $N A J) = x_el
            end
        end
        A
    end
end

############################################################

# x[...] .= f.(y...) ---> broadcast!(f, dotview(x, ...), y...).
# The dotview function defaults to getindex, but we override it in
# a few cases to get the expected in-place behavior without affecting
# explicit calls to view.   (All of this can go away if slices
# are changed to generate views by default.)

dotview(args...) = getindex(args...)
dotview(A::AbstractArray, args...) = view(A, args...)
dotview{T<:AbstractArray}(A::AbstractArray{T}, args...) = getindex(A, args...)
# avoid splatting penalty in common cases:
for nargs = 0:5
    args = Symbol[Symbol("x",i) for i = 1:nargs]
    eval(Expr(:(=), Expr(:call, :dotview, args...),
                    Expr(:call, :getindex, args...)))
    eval(Expr(:(=), Expr(:call, :dotview, :(A::AbstractArray), args...),
                    Expr(:call, :view, :A, args...)))
end

end # module
