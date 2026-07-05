#!/usr/bin/env bash


make clean 
make format 
make 

./load_repo.sh
./test_repo.sh


