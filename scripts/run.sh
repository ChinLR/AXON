#!/bin/bash
cd /scratch/vlsi2_44fs26/axon/reference_flow/sw
make clean all
cd ../verilator && ./run_verilator.sh --build --run ../sw/bin/test1.hex


