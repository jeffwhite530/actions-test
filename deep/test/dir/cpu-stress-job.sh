#!/bin/bash
#SBATCH --job-name=cpu-stress
#SBATCH --output=/tmp/cpu-stress-%j.out
#SBATCH --error=/tmp/cpu-stress-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=00:10:00
#SBATCH --partition=main

echo "Starting CPU stress test at $(date)"
echo "Running on hostname: $(hostname)"
echo "Job ID: ${SLURM_JOB_ID}"
echo "Number of CPUs allocated: ${SLURM_CPUS_ON_NODE}"

# Load any necessary modules (uncomment if needed)
# module load stress-ng

cd /tmp || exit 1

# Run stress-ng with CPU stressor
# --cpu N : Spawn N workers spinning on sqrt(rand())
# --cpu-method matrixprod : Use matrix product method (heavy on CPU)
# --metrics : Show performance metrics
# --timeout x : Run for x
stress-ng --cpu "${SLURM_CPUS_ON_NODE}" \
         --cpu-method matrixprod \
         --metrics \
         --timeout 10m \
         --verbose

echo "Job completed at $(date)"
