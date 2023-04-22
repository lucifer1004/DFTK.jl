using DFTK
using AMDGPU

a = 10.26  # Silicon lattice constant in Bohr
lattice = a / 2 * [[0 1 1.];
                   [1 0 1.];
                   [1 1 0.]]
Si = ElementPsp(:Si, psp=load_psp("hgh/lda/Si-q4"))
atoms     = [Si, Si]
positions = [ones(3)/8, -ones(3)/8]
model = model_PBE(lattice, atoms, positions)

basis  = PlaneWaveBasis(model; Ecut=30, kgrid=(5, 5, 5), architecture=DFTK.GPU(AMDGPU.ROCArray)
scfres = self_consistent_field(basis; tol=1e-2, solver=scf_damping_solver())
