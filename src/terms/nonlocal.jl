import Zygote

@doc raw"""
Nonlocal term coming from norm-conserving pseudopotentials in Kleinmann-Bylander form.
``\text{Energy} = \sum_a \sum_{ij} \sum_{n} f_n <ψ_n|p_{ai}> D_{ij} <p_{aj}|ψ_n>.``
"""
struct AtomicNonlocal end
function (::AtomicNonlocal)(basis::PlaneWaveBasis{T}) where {T}
    model = basis.model

    # keep only pseudopotential atoms and positions
    psp_groups = [group for group in model.atom_groups
                  if model.atoms[first(group)] isa ElementPsp]
    psps          = [model.atoms[first(group)].psp      for group in psp_groups]
    psp_positions = [model.positions[group] for group in psp_groups]

    isempty(psp_groups) && return TermNoop()
    ops = map(basis.kpoints) do kpt
        P = build_projection_vectors_(basis, kpt, psps, psp_positions)
        D = build_projection_coefficients_(T, psps, psp_positions)
        NonlocalOperator(basis, kpt, P, D)
    end
    TermAtomicNonlocal(ops)
end

struct TermAtomicNonlocal <: Term
    ops::Vector{NonlocalOperator}
end

@timing "ene_ops: nonlocal" function ene_ops(term::TermAtomicNonlocal,
                                             basis::PlaneWaveBasis{T},
                                             ψ, occ; kwargs...) where {T}
    isnothing(ψ) && return (E=T(Inf), ops=term.ops)

    E = zero(T)
    for (ik, kpt) in enumerate(basis.kpoints)
        Pψ = term.ops[ik].P' * ψ[ik]  # nproj x nband
        band_enes = dropdims(sum(real.(conj.(Pψ) .* (term.ops[ik].D * Pψ)), dims=1), dims=1)
        E += basis.kweights[ik] * sum(band_enes .* occ[ik])
    end
    E = mpi_sum(E, basis.comm_kpts)

    (E=E, ops=term.ops)
end

@timing "forces: nonlocal" function compute_forces(::TermAtomicNonlocal,
                                                   basis::PlaneWaveBasis{TT},
                                                   ψ, occ; kwargs...) where TT
    T = promote_type(TT, real(eltype(ψ[1])))
    model = basis.model
    unit_cell_volume = model.unit_cell_volume
    psp_groups = [group for group in model.atom_groups
                  if model.atoms[first(group)] isa ElementPsp]

    # early return if no pseudopotential atoms
    isempty(psp_groups) && return nothing

    # energy terms are of the form <psi, P C P' psi>, where P(G) = form_factor(G) * structure_factor(G)
    # forces = [zero(Vec3{T}) for _ in 1:length(model.positions)]
    forces = Zygote.Buffer(zero(model.positions))
    for group in psp_groups
        element = model.atoms[first(group)]

        C = build_projection_coefficients_(element.psp)
        for (ik, kpt) in enumerate(basis.kpoints)
            # we compute the forces from the irreductible BZ; they are symmetrized later
            qs_cart = Gplusk_vectors_cart(basis, kpt)
            qs = Gplusk_vectors(basis, kpt)
            form_factors = build_form_factors(element.psp, qs_cart)
            for idx in group
                r = model.positions[idx]
                structure_factors = [cis2pi(-dot(q, r)) for q in qs]
                P = structure_factors .* form_factors ./ sqrt(unit_cell_volume)

                forces[idx] += map(1:3) do α
                    dPdR = [-2T(π)*im*q[α] for q in qs] .* P
                    ψk = ψ[ik]
                    dHψk = P * (C * (dPdR' * ψk))
                    -sum(occ[ik][iband] * basis.kweights[ik] *
                         2real(dot(ψk[:, iband], dHψk[:, iband]))
                         for iband=1:size(ψk, 2))
                end  # α
            end  # r
        end  # kpt
    end  # group

    # forces = mpi_sum!(forces, basis.comm_kpts) # TODO Zygote
    forces = copy(forces) # unpack Zygote.Buffer
    symmetrize_forces(basis, forces)
end

# returns [a 0; 0 b]
function assemble_block_matrix_(a::Matrix{T}, b::Matrix{T}) where {T}
    cat(a,b,dims=(1,2))
end

# TODO possibly move over to psp/ ?
# TODO possibly move over to pseudo/NormConservingPsp.jl ?
# Build projection coefficients for a atoms array generated by term_nonlocal
# The ordering of the projector indices is (A,l,m,i), where A is running over all
# atoms, l, m are AM quantum numbers and i is running over all projectors for a
# given l. The matrix is block-diagonal with non-zeros only if A, l and m agree.
function build_projection_coefficients_(T, psps, psp_positions)
    # TODO In the current version the proj_coeffs still has a lot of zeros.
    #      One could improve this by storing the blocks as a list or in a
    #      BlockDiagonal data structure
    n_proj = count_n_proj(psps, psp_positions)
    
    if n_proj > 0
        # avoid nested for (contains mutation)
        blocks = [[build_projection_coefficients_(psp) for r in positions] for (psp, positions) in zip(psps, psp_positions)]
        return reduce(assemble_block_matrix_, reduce(vcat, blocks))
    else
        return zeros(T, 0, 0)
    end
end


# Builds the projection coefficient matrix for a single atom
# The ordering of the projector indices is (l,m,i), where l, m are the
# AM quantum numbers and i is running over all projectors for a given l.
# The matrix is block-diagonal with non-zeros only if l and m agree.

function build_projection_coefficients_(psp::NormConservingPsp)
    #@warn "AtomicNonlocal build_projection_coefficients_(psp::NormConservingPsp)"
    blocks = [[psp.h[l + 1] for m in -l:l] for l in 0:psp.lmax]
    proj_coeffs = reduce(assemble_block_matrix_, reduce(vcat,blocks))
    proj_coeffs
end


"""
Build projection vectors for a atoms array generated by term_nonlocal

H_at  = sum_ij Cij |pi> <pj|
H_per = sum_R sum_ij Cij |pi(x-R)> <pj(x-R)|
      = sum_R sum_ij Cij |pi(x-R)> <pj(x-R)|

<e_kG'|H_per|e_kG> = ...
                   = 1/Ω sum_ij Cij pihat(k+G') pjhat(k+G)^*

where pihat(q) = ∫_R^3 pi(r) e^{-iqr} dr

We store 1/√Ω pihat(k+G) in proj_vectors.
"""
function build_projection_vectors_(basis::PlaneWaveBasis{T}, kpt::Kpoint,
                                   psps, psp_positions) where {T}
    unit_cell_volume = basis.model.unit_cell_volume
    sqrt_v = sqrt(unit_cell_volume)
    n_proj = count_n_proj(psps, psp_positions)
    n_G    = length(G_vectors(basis, kpt))
    
    # Compute the columns of proj_vectors = 1/√Ω pihat(k+G)
    # Since the pi are translates of each others, pihat(k+G) decouples as
    # pihat(q) = ∫ p(r-R) e^{-iqr} dr = e^{-iqR} phat(q).
    # The first term is the structure factor, the second the form factor.

    if n_proj > 0
        function structure_factors(r)
            map(q -> cis(-2T(π) * dot(q, r)), Gplusk_vectors(basis, kpt))
        end
        # produces count_n_proj(psp) columns of the projection vectors
        function build_columns(psp, positions)
            # Compute position-independent form factors
            form_factors = build_form_factors(psp, Gplusk_vectors_cart(basis, kpt))
            # Combine with structure factors
            # k+G in this formula can also be G, this only changes an unimportant phase factor
            n_cols = count_n_proj(psp)
            cols = [[structure_factors(r) .* form_factors[:, i] ./ sqrt_v for i = 1:n_cols] for r in positions]
            # reduce Vector{Vector{Vector{T}}} to Matrix{T}
            return reduce(hcat, reduce(vcat, cols))
        end
        proj_vectors = reduce(hcat, [build_columns(psp, positions) for (psp, positions) in zip(psps, psp_positions)])
        return proj_vectors
    else
        return zeros(Complex{T}, n_G, n_proj)
    end
end

"""
Build form factors (Fourier transforms of projectors) for an atom centered at 0.
"""
function build_form_factors(psp, qs)
    qnorms = norm.(qs)
    T = real(eltype(qnorms))
    # Compute position-independent form factors
    if psp.lmax > 0
        function build_factor(l,m)
            prefac_lm = im^l .* ylm_real.(l, m, qs)
            n_proj_l = size(psp.h[l + 1], 1)

            form_factors_local = reduce(hcat, [prefac_lm .* eval_psp_projector_fourier.(psp, iproj, l, qnorms) for iproj in 1:n_proj_l])

            form_factors_local
        end
        # for avoid nested for loop for Zygote compat
        form_factors = reduce(vcat, [[build_factor(l,m) for m in -l:l] for l in 0:psp.lmax]) # build
        return reduce(hcat, form_factors) # concat horizontally
    else
        return zeros(Complex{T}, length(qs), count_n_proj(psp))
    end
end
