// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vspeculative_decode_e2e_top.h for the primary calling header

#ifndef _VSPECULATIVE_DECODE_E2E_TOP_PE_MAC_UNIT__L8_D100_DB10_H_
#define _VSPECULATIVE_DECODE_E2E_TOP_PE_MAC_UNIT__L8_D100_DB10_H_  // guard

#include "verilated.h"
#include "Vspeculative_decode_e2e_top__Dpi.h"

//==========

class Vspeculative_decode_e2e_top__Syms;

//----------

VL_MODULE(Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10) {
  public:
    
    // PORTS
    VL_IN8(clk,0,0);
    VL_IN8(rst_n,0,0);
    VL_IN8(clear,0,0);
    VL_IN8(mac_valid,0,0);
    VL_IN8(depth_cfg,7,0);
    VL_OUT8(done,0,0);
    VL_IN16(vector_val,15,0);
    VL_INW(weight_col,127,0,4);
    VL_OUTW(result,127,0,4);
    
    // LOCAL SIGNALS
    // Anonymous structures to workaround compiler member-count bugs
    struct {
        CData/*7:0*/ __PVT__cycle_cnt_r;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_mult__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_mult__DOT__exponent;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__exponent;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__exponentA;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__exponentB;
        CData/*7:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__shiftAmount;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__cout;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_mult__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_mult__DOT__exponent;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__exponent;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__exponentA;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__exponentB;
        CData/*7:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__shiftAmount;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__cout;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_mult__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_mult__DOT__exponent;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__exponent;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__exponentA;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__exponentB;
        CData/*7:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__shiftAmount;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__cout;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_mult__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_mult__DOT__exponent;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__exponent;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__exponentA;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__exponentB;
        CData/*7:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__shiftAmount;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__cout;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_mult__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_mult__DOT__exponent;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__exponent;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__exponentA;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__exponentB;
        CData/*7:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__shiftAmount;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__cout;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_mult__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_mult__DOT__exponent;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__exponent;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__exponentA;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__exponentB;
        CData/*7:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__shiftAmount;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__cout;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_mult__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_mult__DOT__exponent;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__exponent;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__exponentA;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__exponentB;
        CData/*7:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__shiftAmount;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__cout;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_mult__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_mult__DOT__exponent;
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__sign;
        CData/*5:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__exponent;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__exponentA;
        CData/*4:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__exponentB;
        CData/*7:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__shiftAmount;
    };
    struct {
        CData/*0:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__cout;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_mult__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_mult__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_mult__DOT__fractionB;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__fractionB;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_add__DOT__fraction;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_mult__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_mult__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_mult__DOT__fractionB;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__fractionB;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_add__DOT__fraction;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_mult__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_mult__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_mult__DOT__fractionB;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__fractionB;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_add__DOT__fraction;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_mult__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_mult__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_mult__DOT__fractionB;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__fractionB;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_add__DOT__fraction;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_mult__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_mult__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_mult__DOT__fractionB;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__fractionB;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_add__DOT__fraction;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_mult__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_mult__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_mult__DOT__fractionB;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__fractionB;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_add__DOT__fraction;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_mult__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_mult__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_mult__DOT__fractionB;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__fractionB;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_add__DOT__fraction;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_mult__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_mult__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_mult__DOT__fractionB;
        SData/*9:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__mantissa;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__fractionA;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__fractionB;
        SData/*10:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_add__DOT__fraction;
        WData/*127:0*/ __PVT__mul_w[4];
        WData/*127:0*/ __PVT__add_w[4];
        WData/*127:0*/ __PVT__accum_r[4];
        IData/*21:0*/ __PVT__gen_mac_lane__BRA__0__KET____DOT__u_mult__DOT__fraction;
        IData/*21:0*/ __PVT__gen_mac_lane__BRA__1__KET____DOT__u_mult__DOT__fraction;
        IData/*21:0*/ __PVT__gen_mac_lane__BRA__2__KET____DOT__u_mult__DOT__fraction;
        IData/*21:0*/ __PVT__gen_mac_lane__BRA__3__KET____DOT__u_mult__DOT__fraction;
    };
    struct {
        IData/*21:0*/ __PVT__gen_mac_lane__BRA__4__KET____DOT__u_mult__DOT__fraction;
        IData/*21:0*/ __PVT__gen_mac_lane__BRA__5__KET____DOT__u_mult__DOT__fraction;
        IData/*21:0*/ __PVT__gen_mac_lane__BRA__6__KET____DOT__u_mult__DOT__fraction;
        IData/*21:0*/ __PVT__gen_mac_lane__BRA__7__KET____DOT__u_mult__DOT__fraction;
    };
    
    // LOCAL VARIABLES
    CData/*0:0*/ gen_mac_lane__BRA__0__KET____DOT__u_add__DOT____Vconcswap1;
    CData/*0:0*/ gen_mac_lane__BRA__1__KET____DOT__u_add__DOT____Vconcswap1;
    CData/*0:0*/ gen_mac_lane__BRA__2__KET____DOT__u_add__DOT____Vconcswap1;
    CData/*0:0*/ gen_mac_lane__BRA__3__KET____DOT__u_add__DOT____Vconcswap1;
    CData/*0:0*/ gen_mac_lane__BRA__4__KET____DOT__u_add__DOT____Vconcswap1;
    CData/*0:0*/ gen_mac_lane__BRA__5__KET____DOT__u_add__DOT____Vconcswap1;
    CData/*0:0*/ gen_mac_lane__BRA__6__KET____DOT__u_add__DOT____Vconcswap1;
    CData/*0:0*/ gen_mac_lane__BRA__7__KET____DOT__u_add__DOT____Vconcswap1;
    CData/*7:0*/ __Vdly__cycle_cnt_r;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__0__KET____DOT__u_mult__product;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__0__KET____DOT__u_add__sum;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__1__KET____DOT__u_mult__product;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__1__KET____DOT__u_add__sum;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__2__KET____DOT__u_mult__product;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__2__KET____DOT__u_add__sum;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__3__KET____DOT__u_mult__product;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__3__KET____DOT__u_add__sum;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__4__KET____DOT__u_mult__product;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__4__KET____DOT__u_add__sum;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__5__KET____DOT__u_mult__product;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__5__KET____DOT__u_add__sum;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__6__KET____DOT__u_mult__product;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__6__KET____DOT__u_add__sum;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__7__KET____DOT__u_mult__product;
    SData/*15:0*/ __Vcellout__gen_mac_lane__BRA__7__KET____DOT__u_add__sum;
    SData/*10:0*/ gen_mac_lane__BRA__0__KET____DOT__u_add__DOT____Vconcswap2;
    SData/*10:0*/ gen_mac_lane__BRA__1__KET____DOT__u_add__DOT____Vconcswap2;
    SData/*10:0*/ gen_mac_lane__BRA__2__KET____DOT__u_add__DOT____Vconcswap2;
    SData/*10:0*/ gen_mac_lane__BRA__3__KET____DOT__u_add__DOT____Vconcswap2;
    SData/*10:0*/ gen_mac_lane__BRA__4__KET____DOT__u_add__DOT____Vconcswap2;
    SData/*10:0*/ gen_mac_lane__BRA__5__KET____DOT__u_add__DOT____Vconcswap2;
    SData/*10:0*/ gen_mac_lane__BRA__6__KET____DOT__u_add__DOT____Vconcswap2;
    SData/*10:0*/ gen_mac_lane__BRA__7__KET____DOT__u_add__DOT____Vconcswap2;
    
    // INTERNAL VARIABLES
  private:
    Vspeculative_decode_e2e_top__Syms* __VlSymsp;  // Symbol table
  public:
    
    // CONSTRUCTORS
  private:
    VL_UNCOPYABLE(Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10);  ///< Copying not allowed
  public:
    Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10(const char* name = "TOP");
    ~Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10();
    
    // INTERNAL METHODS
    void __Vconfigure(Vspeculative_decode_e2e_top__Syms* symsp, bool first);
  private:
    void _ctor_var_reset() VL_ATTR_COLD;
  public:
    void _sequent__TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__0__KET____DOT__u_mac__1(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
    void _sequent__TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__0__KET____DOT__u_mac__5(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
    void _sequent__TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__1__KET____DOT__u_mac__2(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
    void _sequent__TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__1__KET____DOT__u_mac__6(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
    void _sequent__TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__2__KET____DOT__u_mac__3(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
    void _sequent__TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__2__KET____DOT__u_mac__7(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
    void _sequent__TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__3__KET____DOT__u_mac__4(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
    void _sequent__TOP__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__3__KET____DOT__u_mac__8(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
} VL_ATTR_ALIGNED(VL_CACHE_LINE_BYTES);

//----------


#endif  // guard
