#!/bin/bash
#SBATCH --job-name=hello-world
#SBATCH --output=/tmp/job-%j.out
#SBATCH --error=/tmp/job-%j.err
#SBATCH --ntasks=1
#SBATCH --mem=1G
#SBATCH --partition=main

echo "Starting job at $(date)"

echo "Running on hostname: $(hostname)"
echo "Job ID: ${SLURM_JOB_ID}"
echo "Job name: ${SLURM_JOB_NAME}"
echo "Allocated nodes: ${SLURM_JOB_NODELIST}"
echo "Number of CPUs allocated: ${SLURM_CPUS_ON_NODE}"

echo "Job completed at $(date)"
