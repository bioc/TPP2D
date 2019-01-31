# TPP2D: FDR-controlled analysis of 2D-TPP datasets with R
[![Build Status](https://travis-ci.org/nkurzaw/TPP2D.svg?branch=master)](https://travis-ci.org/nkurzaw/TPP2D)
[![codecov](https://codecov.io/gh/nkurzaw/TPP2D/branch/master/graph/badge.svg)](https://codecov.io/gh/nkurzaw/TPP2D)

This package contains functions to analyze 2D-thermal proteome profiles using a functional analysis approach. This is done by fitting two competing models (H0 and H1) to the thermal profile of each protein and asking whether the H1 model explains the variance in the data significantly better than the H0.

## Installation

```{R}
require("devtools")
devtools::install_github("nkurzaw/TPP2D")
```

