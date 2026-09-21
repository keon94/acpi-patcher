#!/bin/sh

iasl -ve -tc \
  -p build/nvd1-alias \
  patches/nvd1-alias.dsl
