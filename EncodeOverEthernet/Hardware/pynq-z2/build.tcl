# Recreate the Vivado project for the EncodeOverEthernet demo on the PYNQ-Z2
# and optionally build the bitstream. The block design itself lives in
# design_encode_ethernet.tcl (write_bd_tcl export, pinned to Vivado 2025.2).
#
# Usage:
#   vivado -mode batch -source build.tcl                      # project only
#   vivado -mode batch -source build.tcl -tclargs --bitstream # + bitstream
#
# The project lands in ./build/ (git-ignored) — the Tcl scripts are the
# source of truth; never commit the generated project.

set demo_dir [file dirname [file normalize [info script]]]
set openjls_dir [file normalize [file join $demo_dir .. .. .. ThirdParty OpenJLS]]

create_project encode_ethernet [file join $demo_dir build] -part xc7z020clg400-1 -force
set_property target_language VHDL [current_project]

# Board files come from the Vivado Board Store; the design still builds
# without them since the PS configuration is baked into the BD script.
if {[catch {set_property BOARD_PART tul.com.tw:pynq-z2:part0:1.0 [current_project]} err]} {
    puts "WARNING: PYNQ-Z2 board files not installed, continuing with bare part: $err"
}

# OpenJLS RTL + AXI wrappers (VHDL-2008, default library), then the
# open-logic primitives they instantiate, via the core's own script.
set ojls_files [concat \
    [glob [file join $openjls_dir Sources *.vhd]] \
    [glob [file join $openjls_dir Sources axi *.vhd]]]
add_files -fileset sources_1 $ojls_files
set_property FILE_TYPE {VHDL 2008} [get_files $ojls_files]
source [file join $openjls_dir Scripts create_libraries_vivado.tcl]

# Block design, then its HDL wrapper as top. All I/O is through the PS
# (DDR/FIXED_IO), so there is no XDC.
source [file join $demo_dir design_encode_ethernet.tcl]
if {[get_files -quiet design_encode_ethernet.bd] eq ""} {
    error "Block design was not created — see the messages above (Vivado version mismatch?)."
}
set wrapper [make_wrapper -files [get_files design_encode_ethernet.bd] -top]
add_files -norecurse $wrapper
set_property top design_encode_ethernet_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

if {[info exists argv] && [lsearch $argv "--bitstream"] >= 0} {
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        error "Implementation failed — open the project under ./build/ to inspect."
    }
    puts "Bitstream: [glob [file join $demo_dir build encode_ethernet.runs impl_1 *.bit]]"
}
