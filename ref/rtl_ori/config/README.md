# Config Headers

This directory holds shared RTL configuration headers for the single-chiplet
project.

## Rules

1. put shared macros here before copying constants into RTL files
2. keep comments explicit about which values are frozen and which are version-1
   placeholders
3. update the matching design docs whenever a value changes
4. do not silently turn a placeholder into a frozen architecture decision

## Current files

- `memory_params.vh`
- `model_params.vh`
- `prediction_params.vh`
- `interface_params.vh`

## Usage guidance

1. include only the headers a module actually needs
2. prefer parameterized module ports over hidden local magic numbers
3. when a placeholder becomes architecture-final, update both this directory and
   `docs/design/`
