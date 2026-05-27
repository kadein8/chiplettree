// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Symbol table implementation internals

#include "Vspeculative_decode_e2e_top__Syms.h"
#include "Vspeculative_decode_e2e_top.h"
#include "Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10.h"



// FUNCTIONS
Vspeculative_decode_e2e_top__Syms::Vspeculative_decode_e2e_top__Syms(Vspeculative_decode_e2e_top* topp, const char* namep)
    // Setup locals
    : __Vm_namep(namep)
    , __Vm_didInit(false)
    // Setup submodule names
    , TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__0__KET____DOT__u_mac(Verilated::catName(topp->name(), "speculative_decode_e2e_top.u_layer_ctrl.gen_slot_mac[0].u_mac"))
    , TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__1__KET____DOT__u_mac(Verilated::catName(topp->name(), "speculative_decode_e2e_top.u_layer_ctrl.gen_slot_mac[1].u_mac"))
    , TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__2__KET____DOT__u_mac(Verilated::catName(topp->name(), "speculative_decode_e2e_top.u_layer_ctrl.gen_slot_mac[2].u_mac"))
    , TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__3__KET____DOT__u_mac(Verilated::catName(topp->name(), "speculative_decode_e2e_top.u_layer_ctrl.gen_slot_mac[3].u_mac"))
{
    // Pointer to top level
    TOPp = topp;
    // Setup each module's pointers to their submodules
    TOPp->__PVT__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__0__KET____DOT__u_mac = &TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__0__KET____DOT__u_mac;
    TOPp->__PVT__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__1__KET____DOT__u_mac = &TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__1__KET____DOT__u_mac;
    TOPp->__PVT__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__2__KET____DOT__u_mac = &TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__2__KET____DOT__u_mac;
    TOPp->__PVT__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__3__KET____DOT__u_mac = &TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__3__KET____DOT__u_mac;
    // Setup each module's pointer back to symbol table (for public functions)
    TOPp->__Vconfigure(this, true);
    TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__0__KET____DOT__u_mac.__Vconfigure(this, true);
    TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__1__KET____DOT__u_mac.__Vconfigure(this, false);
    TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__2__KET____DOT__u_mac.__Vconfigure(this, false);
    TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__3__KET____DOT__u_mac.__Vconfigure(this, false);
    // Setup export functions
    for (int __Vfinal=0; __Vfinal<2; __Vfinal++) {
    }
}
