/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/


/*----------------------------------------------------------------------------80
The abstract base class (ABC) for the ensemble classes.
------------------------------------------------------------------------------*/


#include "ensemble.cuh"
#include "atom.cuh"
#include "error.cuh"
#include "force.cuh"

#define BLOCK_SIZE 128
#define DIM 3


Ensemble::Ensemble(void)
{
    // nothing now
}

Ensemble::~Ensemble(void)
{
    // nothing now
}


static __global__ void gpu_velocity_verlet
(
    const bool is_step1,
    const int number_of_particles,
    const int fixed_group,
    const int *group_id,
    const double g_time_step,
    const double* g_mass,
    double* g_x,
    double* g_y,
    double* g_z,
    double* g_vx,
    double* g_vy,
    double* g_vz,
    const double* g_fx,
    const double* g_fy,
    const double* g_fz
)
{
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < number_of_particles)
    {
        const double time_step = g_time_step;
        const double time_step_half = time_step * 0.5;
        double vx = g_vx[i];
        double vy = g_vy[i];
        double vz = g_vz[i];
        const double mass_inv = 1.0 / g_mass[i];
        const double ax = g_fx[i] * mass_inv;
        const double ay = g_fy[i] * mass_inv;
        const double az = g_fz[i] * mass_inv;
        if (group_id[i] == fixed_group)
        {
            vx = 0.0;
            vy = 0.0;
            vz = 0.0;
        }
        else
        {
            vx += ax * time_step_half;
            vy += ay * time_step_half;
            vz += az * time_step_half;
        }
        g_vx[i] = vx;
        g_vy[i] = vy;
        g_vz[i] = vz;
        if (is_step1)
        {
            g_x[i] += vx * time_step;
            g_y[i] += vy * time_step;
            g_z[i] += vz * time_step;
        }
    }
}


static __global__ void gpu_velocity_verlet
(
    const bool is_step1,
    const int number_of_particles,
    const double g_time_step,
    const double* g_mass,
    double* g_x,
    double* g_y,
    double* g_z,
    double* g_vx,
    double* g_vy,
    double* g_vz,
    const double* g_fx,
    const double* g_fy,
    const double* g_fz
)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < number_of_particles)
    {
        const double time_step = g_time_step;
        const double time_step_half = time_step * 0.5;
        double vx = g_vx[i];
        double vy = g_vy[i];
        double vz = g_vz[i];
        const double mass_inv = 1.0 / g_mass[i];
        const double ax = g_fx[i] * mass_inv;
        const double ay = g_fy[i] * mass_inv;
        const double az = g_fz[i] * mass_inv;
        vx += ax * time_step_half;
        vy += ay * time_step_half;
        vz += az * time_step_half;
        g_vx[i] = vx;
        g_vy[i] = vy;
        g_vz[i] = vz;
        if (is_step1)
        {
            g_x[i] += vx * time_step;
            g_y[i] += vy * time_step;
            g_z[i] += vz * time_step;
        }
    }
}


void Ensemble::velocity_verlet(const bool is_step1, Atom* atom)
{
    if (fixed_group == -1)
    {
        gpu_velocity_verlet<<<(atom->N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
        (
            is_step1,
            atom->N,
            atom->time_step,
            atom->mass.data(),
            atom->position_per_atom.data(),
            atom->position_per_atom.data() + atom->N,
            atom->position_per_atom.data() + atom->N * 2,
            atom->velocity_per_atom.data(),
            atom->velocity_per_atom.data() + atom->N,
            atom->velocity_per_atom.data() + 2 * atom->N,
            atom->force_per_atom.data(),
            atom->force_per_atom.data() + atom->N,
            atom->force_per_atom.data() + 2 * atom->N
        );
    }
    else
    {
        gpu_velocity_verlet<<<(atom->N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
        (
            is_step1,
            atom->N,
            fixed_group,
            atom->group[0].label.data(),
            atom->time_step,
            atom->mass.data(),
            atom->position_per_atom.data(),
            atom->position_per_atom.data() + atom->N,
            atom->position_per_atom.data() + atom->N * 2,
            atom->velocity_per_atom.data(),
            atom->velocity_per_atom.data() + atom->N,
            atom->velocity_per_atom.data() + 2 * atom->N,
            atom->force_per_atom.data(),
            atom->force_per_atom.data() + atom->N,
            atom->force_per_atom.data() + 2 * atom->N
        );

    }
    CUDA_CHECK_KERNEL
}


// Find some thermodynamic properties:
// g_thermo[0-4] = T, U, p_x, p_y, p_z
static __global__ void gpu_find_thermo
(
    int N,
    int N_fixed,
    int fixed_group,
    int *group_id,
    double T,
    double volume,
    double *g_mass,
    double *g_potential,
    double *g_vx,
    double *g_vy,
    double *g_vz,
    double *g_sx,
    double *g_sy,
    double *g_sz,
    double *g_thermo
)
{
    //<<<5, MAX_THREAD>>>
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int patch, n;
    int number_of_patches = (N - 1) / 1024 + 1;
    double mass, vx, vy, vz;

    switch (bid)
    {
        case 0:
            __shared__ double s_ke[1024];
            s_ke[tid] = 0.0;
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N && group_id[n] != fixed_group)
                {
                    mass = g_mass[n];
                    vx = g_vx[n]; vy = g_vy[n]; vz = g_vz[n];
                    s_ke[tid] += (vx * vx + vy * vy + vz * vz) * mass;
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_ke[tid] += s_ke[tid + offset]; }
                __syncthreads();
            }
            if (tid ==  0)
            {
                g_thermo[0] = s_ke[0] / (DIM * (N - N_fixed) * K_B);
            }
            break;
        case 1:
            __shared__ double s_pe[1024];
            s_pe[tid] = 0.0;
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N && group_id[n] != fixed_group)
                {          
                    s_pe[tid] += g_potential[n];
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_pe[tid] += s_pe[tid + offset]; }
                __syncthreads();
            } 
            if (tid ==  0) g_thermo[1] = s_pe[0];
            break;
        case 2:
            __shared__ double s_sx[1024];
            s_sx[tid] = 0.0;
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N && group_id[n] != fixed_group)
                {
                    s_sx[tid] += g_sx[n];
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_sx[tid] += s_sx[tid + offset]; }
                __syncthreads();
            }
            if (tid == 0)
            {
                g_thermo[2] = (s_sx[0] + N * K_B * T) / volume;
            }
            break;
        case 3:
            __shared__ double s_sy[1024];
            s_sy[tid] = 0.0; 
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N && group_id[n] != fixed_group)
                {        
                    s_sy[tid] += g_sy[n];
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_sy[tid] += s_sy[tid + offset]; }
                __syncthreads();
            }
            if (tid == 0)
            {
                g_thermo[3] = (s_sy[0] + N * K_B * T) / volume;
            }
            break;
        case 4:
            __shared__ double s_sz[1024];
            s_sz[tid] = 0.0;
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N && group_id[n] != fixed_group)
                {
                    s_sz[tid] += g_sz[n];
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_sz[tid] += s_sz[tid + offset]; }
                __syncthreads();
            }
            if (tid == 0)
            {
                g_thermo[4] = (s_sz[0] + N * K_B * T) / volume;
            }
            break;
    }
}


// Find some thermodynamic properties:
// g_thermo[0-4] = T, U, p_x, p_y, p_z
static __global__ void gpu_find_thermo
(
    int N,
    double T,
    double volume,
    double *g_mass,
    double *g_potential,
    double *g_vx,
    double *g_vy,
    double *g_vz,
    double *g_sx,
    double *g_sy,
    double *g_sz,
    double *g_thermo
)
{
    //<<<5, MAX_THREAD>>>
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int patch, n;
    int number_of_patches = (N - 1) / 1024 + 1;
    double mass, vx, vy, vz;

    switch (bid)
    {
        case 0:
            __shared__ double s_ke[1024];
            s_ke[tid] = 0.0;
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N)
                {
                    mass = g_mass[n];
                    vx = g_vx[n]; vy = g_vy[n]; vz = g_vz[n];
                    s_ke[tid] += (vx * vx + vy * vy + vz * vz) * mass;
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_ke[tid] += s_ke[tid + offset]; }
                __syncthreads();
            }
            if (tid ==  0)
            {
                g_thermo[0] = s_ke[0] / (DIM * N * K_B);
            }
            break;
        case 1:
            __shared__ double s_pe[1024];
            s_pe[tid] = 0.0;
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N)
                {          
                    s_pe[tid] += g_potential[n];
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_pe[tid] += s_pe[tid + offset]; }
                __syncthreads();
            }
            if (tid ==  0) g_thermo[1] = s_pe[0];
            break;
        case 2:
            __shared__ double s_sx[1024];
            s_sx[tid] = 0.0;
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N)
                {
                    s_sx[tid] += g_sx[n];
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_sx[tid] += s_sx[tid + offset]; }
                __syncthreads();
            }
            if (tid == 0)
            {
                g_thermo[2] = (s_sx[0] + N * K_B * T) / volume;
            }
            break;
        case 3:
            __shared__ double s_sy[1024];
            s_sy[tid] = 0.0; 
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N)
                {        
                    s_sy[tid] += g_sy[n];
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_sy[tid] += s_sy[tid + offset]; }
                __syncthreads();
            }
            if (tid == 0)
            {
                g_thermo[3] = (s_sy[0] + N * K_B * T) / volume;
            }
            break;
        case 4:
            __shared__ double s_sz[1024];
            s_sz[tid] = 0.0;
            for (patch = 0; patch < number_of_patches; ++patch)
            {
                n = tid + patch * 1024;
                if (n < N)
                {
                    s_sz[tid] += g_sz[n];
                }
            }
            __syncthreads();
            #pragma unroll
            for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
            {
                if (tid < offset) { s_sz[tid] += s_sz[tid + offset]; }
                __syncthreads();
            }
            if (tid == 0)
            {
                g_thermo[4] = (s_sz[0] + N * K_B * T) / volume;
            }
            break;
    }
}


// wrapper of the above kernel
void Ensemble::find_thermo(Atom* atom)
{
    double volume = atom->box.get_volume();
    if (fixed_group == -1)
    {
        gpu_find_thermo<<<5, 1024>>>
        (
            atom->N,
            temperature,
            volume,
            atom->mass.data(),
            atom->potential_per_atom.data(),
            atom->velocity_per_atom.data(),
            atom->velocity_per_atom.data() + atom->N,
            atom->velocity_per_atom.data() + 2 * atom->N,
            atom->virial_per_atom.data(),
            atom->virial_per_atom.data() + atom->N,
            atom->virial_per_atom.data() + atom->N * 2,
            atom->thermo.data()
        );
    }
    else
    {
        int N_fixed = atom->group[0].cpu_size[fixed_group];
        gpu_find_thermo<<<5, 1024>>>
        (
            atom->N,
            N_fixed,
            fixed_group,
            atom->group[0].label.data(),
            temperature,
            volume,
            atom->mass.data(),
            atom->potential_per_atom.data(),
            atom->velocity_per_atom.data(),
            atom->velocity_per_atom.data() + atom->N,
            atom->velocity_per_atom.data() + 2 * atom->N,
            atom->virial_per_atom.data(),
            atom->virial_per_atom.data() + atom->N,
            atom->virial_per_atom.data() + atom->N * 2,
            atom->thermo.data()
        );
    }
    CUDA_CHECK_KERNEL
}


// Scale the velocity of every particle in the systems by a factor
static void __global__ gpu_scale_velocity
(
    const int N,
    const double factor,
    double *g_vx,
    double *g_vy,
    double *g_vz
)
{
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < N)
    {
        g_vx[i] *= factor;
        g_vy[i] *= factor;
        g_vz[i] *= factor;
    }
}


// wrapper of the above kernel
void Ensemble::scale_velocity_global
(
    const double factor,
    GPU_Vector<double>& velocity_per_atom
)
{
    const int number_of_atoms = velocity_per_atom.size() / 3;
    gpu_scale_velocity<<<(number_of_atoms - 1) / 128 + 1, 128>>>
    (
        number_of_atoms,
        factor,
        velocity_per_atom.data(),
        velocity_per_atom.data() + number_of_atoms,
        velocity_per_atom.data() + 2 * number_of_atoms
    );
    CUDA_CHECK_KERNEL
}


static __global__ void gpu_find_vc_and_ke
(
    const int* g_group_size,
    const int* g_group_size_sum,
    const int* g_group_contents,
    const double* g_mass,
    const double *g_vx,
    const double *g_vy,
    const double *g_vz,
    double *g_vcx,
    double *g_vcy,
    double *g_vcz,
    double *g_ke
)
{
    //<<<number_of_groups, 512>>>

    int tid = threadIdx.x;
    int bid = blockIdx.x;

    int group_size = g_group_size[bid];
    int offset = g_group_size_sum[bid];
    int number_of_patches = (group_size - 1) / 512 + 1; 

    __shared__ double s_mc[512]; // center of mass
    __shared__ double s_vx[512]; // center of mass velocity
    __shared__ double s_vy[512];
    __shared__ double s_vz[512];
    __shared__ double s_ke[512]; // relative kinetic energy

    s_mc[tid] = 0.0;
    s_vx[tid] = 0.0;
    s_vy[tid] = 0.0;
    s_vz[tid] = 0.0;
    s_ke[tid] = 0.0;
    
    for (int patch = 0; patch < number_of_patches; ++patch)
    { 
        int n = tid + patch * 512;
        if (n < group_size)
        {  
            int index = g_group_contents[offset + n];     
            double mass = g_mass[index];
            double vx = g_vx[index];
            double vy = g_vy[index];
            double vz = g_vz[index];

            s_mc[tid] += mass;
            s_vx[tid] += mass * vx;
            s_vy[tid] += mass * vy;
            s_vz[tid] += mass * vz;
            s_ke[tid] += (vx * vx + vy * vy + vz * vz) * mass;
        }
    }
    __syncthreads();

    #pragma unroll
    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
    {
        if (tid < offset) 
        {
            s_mc[tid] += s_mc[tid + offset];
            s_vx[tid] += s_vx[tid + offset];
            s_vy[tid] += s_vy[tid + offset];
            s_vz[tid] += s_vz[tid + offset];
            s_ke[tid] += s_ke[tid + offset];
        }
        __syncthreads();
    }

    if (tid == 0) 
    { 
        double mc = s_mc[0];
        double vx = s_vx[0] / mc;
        double vy = s_vy[0] / mc;
        double vz = s_vz[0] / mc;
        g_vcx[bid] = vx; // center of mass velocity
        g_vcy[bid] = vy;
        g_vcz[bid] = vz;

        // relative kinetic energy times 2
        g_ke[bid] = (s_ke[0] - mc * (vx * vx + vy * vy + vz * vz));  
    }
}


// wrapper of the above kernel
void Ensemble::find_vc_and_ke
(
    const std::vector<Group>& group,
    const GPU_Vector<double>& mass,
    const GPU_Vector<double>& velocity_per_atom,
    double* vcx,
    double* vcy,
    double* vcz,
    double* ke
)
{
    const int number_of_atoms = mass.size();

    gpu_find_vc_and_ke<<<group[0].number, 512>>>
    (
        group[0].size.data(),
        group[0].size_sum.data(),
        group[0].contents.data(),
        mass.data(),
        velocity_per_atom.data(),
        velocity_per_atom.data() + number_of_atoms,
        velocity_per_atom.data() + 2 * number_of_atoms,
        vcx,
        vcy,
        vcz,
        ke
    );
    CUDA_CHECK_KERNEL
}


static __global__ void gpu_scale_velocity
(
    const int number_of_particles,
    const int label_1,
    const int label_2,
    const int *g_atom_label,
    const double factor_1,
    const double factor_2,
    const double *g_vcx,
    const double *g_vcy,
    const double *g_vcz,
    const double *g_ke,
    double *g_vx,
    double *g_vy,
    double *g_vz
)
{
    // <<<(N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>

    int n = blockIdx.x * blockDim.x + threadIdx.x;
    if (n < number_of_particles)
    {
        int atom_label = g_atom_label[n];     
                 
        if (atom_label == label_1) 
        {
            // center of mass velocity for the source
            double vcx = g_vcx[atom_label]; 
            double vcy = g_vcy[atom_label];
            double vcz = g_vcz[atom_label];  

            // momentum is conserved
            g_vx[n] = vcx + factor_1 * (g_vx[n] - vcx);
            g_vy[n] = vcy + factor_1 * (g_vy[n] - vcy);
            g_vz[n] = vcz + factor_1 * (g_vz[n] - vcz);
        }
        if (atom_label == label_2)
        {
            // center of mass velocity for the sink
            double vcx = g_vcx[atom_label]; 
            double vcy = g_vcy[atom_label];
            double vcz = g_vcz[atom_label];  

            // momentum is conserved
            g_vx[n] = vcx + factor_2 * (g_vx[n] - vcx);
            g_vy[n] = vcy + factor_2 * (g_vy[n] - vcy);
            g_vz[n] = vcz + factor_2 * (g_vz[n] - vcz);
        }
    }
}


// wrapper of the above kernel
void Ensemble::scale_velocity_local
(
    const double factor_1,
    const double factor_2,
    const double* vcx,
    const double* vcy,
    const double* vcz,
    const double* ke,
    const std::vector<Group>& group,
    GPU_Vector<double>& velocity_per_atom
)
{
    const int number_of_atoms = velocity_per_atom.size() / 3;

    gpu_scale_velocity<<<(number_of_atoms - 1) / 128 + 1, 128>>>
    (
        number_of_atoms,
        source,
        sink,
        group[0].label.data(),
        factor_1,
        factor_2,
        vcx,
        vcy,
        vcz,
        ke,
        velocity_per_atom.data(),
        velocity_per_atom.data() + number_of_atoms,
        velocity_per_atom.data() + 2 * number_of_atoms
    );
    CUDA_CHECK_KERNEL
}


