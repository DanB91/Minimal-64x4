#!/bin/bash

BUILD_DIR=build
NAME=m64x4

if [[ ! -d $BUILD_DIR ]]; then
    mkdir $BUILD_DIR
fi



# if odin build . -o:speed -debug -out:$BUILD_DIR/$NAME && [[ $1 == "run" ]]; then
if odin build . -o:none -debug -out:$BUILD_DIR/$NAME && [[ $1 == "run" ]]; then
    $BUILD_DIR/$NAME
fi