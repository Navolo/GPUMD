import numpy as np

from ase.build import bulk
from ase.calculators.emt import EMT

from hiphive import ClusterSpace, ForceConstantPotential, StructureContainer
from hiphive.calculators import ForceConstantCalculator
from hiphive.input_output.gpumd import write_atoms_gpumd, write_r0
from hiphive.utilities import prepare_structure
from hiphive.fitting import Optimizer


# setup
prim = bulk('Al', 'fcc', cubic=True)
supercell = prim.repeat(4)
cs = ClusterSpace(prim, [5.0, 5.0, 4.5, 4.0, 4.0])

# train FCP
sc = StructureContainer(cs)
for i in range(3):
    atoms = supercell.copy()
    atoms.rattle(0.3, seed=100*i)
    atoms = prepare_structure(atoms, supercell, calc=EMT())
    sc.add_structure(atoms)
opt = Optimizer(sc.get_fit_data())
opt.train()
print(opt)


# get fcs
fcp = ForceConstantPotential(cs, opt.parameters)
fcs = fcp.get_force_constants(supercell)


# calculate reference forces
supercell_rattle = supercell.copy()
supercell_rattle.rattle(0.2)
calc = ForceConstantCalculator(fcs)
supercell_rattle.set_calculator(calc)
forces = supercell_rattle.get_forces()
np.savetxt('forces_hiphive.txt', forces)


# write gpumd files
write_atoms_gpumd('xyz.in', supercell_rattle)
write_r0('r0.in', supercell)

for order in fcs.orders:
    fname1 = 'fcs_order{}'.format(order)
    fname2 = 'clusters_order{}'.format(order)
    fcs.write_to_GPUMD(fname1, fname2, order=order)
