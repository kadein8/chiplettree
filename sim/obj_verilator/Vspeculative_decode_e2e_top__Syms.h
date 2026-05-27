// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Symbol table internal header
//
// Internal details; most calling programs do not need this header,
// unless using verilator public meta comments.

#ifndef _VSPECULATIVE_DECODE_E2E_TOP__SYMS_H_
#define _VSPECULATIVE_DECODE_E2E_TOP__SYMS_H_  // guard

#include "verilated.h"

// INCLUDE MODULE CLASSES
#include "Vspeculative_decode_e2e_top.h"
#include "Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10.h"

// SYMS CLASS
class Vspeculative_decode_e2e_top__Syms : public VerilatedSyms {
  public:
    
    // LOCAL STATE
    const char* __Vm_namep;
    bool __Vm_didInit;
    
    // SUBCELL STATE
    Vspeculative_decode_e2e_top*   TOPp;
    Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10 TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__0__KET____DOT__u_mac;
    Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10 TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__1__KET____DOT__u_mac;
    Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10 TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__2__KET____DOT__u_mac;
    Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10 TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__3__KET____DOT__u_mac;
    
    // CREATORS
    Vspeculative_decode_e2e_top__Syms(Vspeculative_decode_e2e_top* topp, const char* namep);
    ~Vspeculative_decode_e2e_top__Syms() {}
    
    // METHODS
    inline const char* name() { return __Vm_namep; }
    
} VL_ATTR_ALIGNED(VL_CACHE_LINE_BYTES);

#endif  // guard
