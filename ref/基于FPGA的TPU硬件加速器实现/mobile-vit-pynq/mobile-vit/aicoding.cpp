#include <iostream>
#include <vector>
#include <cmath>
#include <algorithm>
#include <random>
#include <string>
#include <cstring>
#include <cassert>

// =========================Streaming define===================
#include "ap_axi_sdata.h"
#include "hls_stream.h"
#include <complex.h>
typedef ap_axis<32,2,5,6> packet;
// 定义数据流中的数据类型（可根据精度需求调整）
typedef int data_t;

// 辅助函数：计算填充后的尺寸
inline int padded_size(int size, int padding) {
    return size + 2 * padding;
}

// 辅助函数：计算输出尺寸
inline int output_size(int in_size, int kernel_size, int stride, int padding) {
    return (in_size + 2 * padding - kernel_size) / stride + 1;
}
// 普通2D卷积
void conv2d_hls(hls::stream<packet> &A, hls::stream<packet> &B)
 {
    #pragma HLS INTERFACE axis port=A
    #pragma HLS INTERFACE axis port=B
    packet tmp;
// const Tensor, Tensor& out, const ConvParams& params
    int n = 0, cin = 0, h = 0, w = 0;
    int cout = 0, kh = 0, kw = 0;
    int stride = 0, padding = 0;
        do    
        {
            tmp=A.read();
            n=tmp.data;
            tmp=A.read();
            cin=tmp.data;
            tmp=A.read();
            h=tmp.data;
            tmp=A.read();
            w=tmp.data;
            tmp=A.read();
            cout=tmp.data;
            tmp=A.read();
            kh=tmp.data;
            tmp=A.read();
            kw=tmp.data;
            tmp=A.read();
            stride=tmp.data;
            tmp=A.read();
            padding=tmp.data;
            
        }  while(!tmp.last); 
    // 计算输出维度并验证
    int out_h = (h + 2 * padding - kh) / stride + 1;
    int out_w = (w + 2 * padding - kw) / stride + 1;
    // CHECK_POSITIVE(out_h);
    // CHECK_POSITIVE(out_w);
    // 存储填充后的输入数据
    const int padded_h = padded_size(h, padding);
    const int padded_w = padded_size(w, padding); 

    data_t padded_x[MAX_COUT][MAX_CIN][MAX_HIN][MAX_WIN];
 // 1. 读取输入并进行填充
    for (int b = 0; b < n; ++b) {
        for (int ch = 0; ch < cin; ++ch) {
            for (int y = 0; y < h; ++y) {
                for (int x = 0; x < w; ++x) {
    #pragma HLS PIPELINE II=1  // 流水线处理输入
                    packet in_pixel = A.read();
                    // 填充到中间位置，边缘保持0（默认初始化）
                    padded_x[b][ch][y + padding][x + padding] = in_pixel.data;
                }
            }
        }
    } 
//  2. 读取权重数据
    data_t weights[MAX_COUT*3*3];
    for(int i=0;i<cout*kh*kw;i++){
        packet in_weight=A.read();
        weights[i]=in_weight.data;                
    }
//  3.读取偏置值数据
    data_t bias[MAX_COUT];
    for(int i=0;i<cout;i++){
        packet in_bias=A.read();
        bias[i]=in_bias.data;
    }
     // 2. 执行卷积计算
    for (int b = 0; b < n; ++b) {
        for (int co = 0; co < cout; ++co) {
            const float bias_val = bias[co];
            for (int y = 0; y < out_h; ++y) {
                for (int x = 0; x < out_w; ++x) {
#pragma HLS PIPELINE II=1  // 流水线处理输出
                    float sum = bias_val;
                    
                    // 输入通道循环
                    for (int ci = 0; ci < cin; ++ci) {
                        // 卷积核循环
                        for (int ky = 0; ky < kh; ++ky) {
                            for (int kx = 0; kx < kw; ++kx) {
#pragma HLS UNROLL factor=4  // 部分展开卷积核循环
                                int in_y = y * stride + ky;
                                int in_x = x * stride + kx;
                                
                                // 权重索引计算 (cout, cin, kh, kw)
                                size_t w_idx = co * cin * kh * kw + ci * kh * kw + ky * kw + kx;
                                
                                sum += padded_x[b][ci][in_y][in_x] * weights[w_idx];
                            }
                        }
                    }
                    
                    packet out_pixel;
                    out_pixel.data = sum;
                    // 判断是否为最后一个像素
                    out_pixel.last = (b == n-1) && (co == cout-1) && (y == out_h-1) && (x == out_w-1);
                    B.write(out_pixel);
                }
            }
        }
    }    

}

// 深度可分离2D卷积（输入输出通道数相同）
void depthwise_conv2d(const Tensor& x, Tensor& out, const ConvParams& params) {
    int n = x.n, cin = x.c, h = x.h, w = x.w;
    int kh = params.kh, kw = params.kw;
    int stride = params.stride, padding = params.padding;

    // 计算输出维度并验证
    int out_h = (h + 2 * padding - kh) / stride + 1;
    int out_w = (w + 2 * padding - kw) / stride + 1;
    // 初始化输出张量（通道数与输入相同）
    out = create_tensor(n, cin, out_h, out_w);

    // 创建填充后的输入
    Tensor padded_x = create_tensor(n, cin, h + 2 * padding, w + 2 * padding);
    for (int b = 0; b < n; ++b) {
        for (int ch = 0; ch < cin; ++ch) {
            for (int y = 0; y < h; ++y) {
                for (int x_ = 0; x_ < w; ++x_) {
                    get_tensor_at(padded_x, b, ch, y + padding, x_ + padding) = get_tensor_at_const(x, b, ch, y, x_);
                }
            }
        }
    }

    // 深度卷积计算（单通道对应单卷积核）
    for (int b = 0; b < n; ++b) {
        for (int ch = 0; ch < cin; ++ch) {
            float bias_val = params.bias[ch];
            for (int y = 0; y < out_h; ++y) {
                for (int x_ = 0; x_ < out_w; ++x_) {
                    float sum = bias_val;
                    // 卷积核循环
                    for (int ky = 0; ky < kh; ++ky) {
                        for (int kx = 0; kx < kw; ++kx) {
                            int in_y = y * stride + ky;
                            int in_x = x_ * stride + kx;
                           
                            // 权重索引（cin, kh, kw）
                            size_t w_idx = static_cast<size_t>(ch * kh * kw + ky * kw + kx);
                          
                            sum += get_tensor_at_const(padded_x, b, ch, in_y, in_x) * params.weight[w_idx];
                        }
                    }
                    get_tensor_at(out, b, ch, y, x_) = sum;
                }
            }
        }
    }

    destroy_tensor(padded_x); // 释放临时内存
}



// 线性层（全连接层）
void linear(const Tensor& x, Tensor& out, const LinearParams& params) {
   
    int in_dim = x.c * x.h * x.w; // 输入展平维度
    out = create_tensor(x.n, 1, 1, params.out_features);

    // 展平输入（N,C,H,W → N,1,1,in_dim）
    Tensor x_flat = create_tensor(x.n, 1, 1, in_dim);
    for (int b = 0; b < x.n; ++b) {
        int idx = 0;
        for (int ch = 0; ch < x.c; ++ch) {
            for (int y = 0; y < x.h; ++y) {
                for (int x_ = 0; x_ < x.w; ++x_) {
                    get_tensor_at(x_flat, b, 0, 0, idx++) = get_tensor_at_const(x, b, ch, y, x_);
                }
            }
        }
    }

    // 线性计算：out = x_flat * W^T + b
    for (int b = 0; b < x.n; ++b) {
        for (int out_idx = 0; out_idx < params.out_features; ++out_idx) {
            float sum = params.bias[out_idx];
            for (int in_idx = 0; in_idx < params.in_features; ++in_idx) {
                size_t w_idx = static_cast<size_t>(out_idx * params.in_features + in_idx);
                CHECK_INDEX(w_idx, params.weight.size());
                sum += get_tensor_at_const(x_flat, b, 0, 0, in_idx) * params.weight[w_idx];
            }
            get_tensor_at(out, b, 0, 0, out_idx) = sum;
        }
    }
}

// 对序列中每个元素应用线性层（Transformer输入处理）
void linear_sequence(const Tensor& seq, Tensor& out, const LinearParams& params) {
   
    int n = seq.n, seq_len = seq.c, features = seq.h * seq.w;
    // 初始化输出张量（N, seq_len, 1, out_features）
    out = create_tensor(n, seq_len, 1, params.out_features);

    // 逐个元素应用线性层
    for (int b = 0; b < n; ++b) {
        for (int i = 0; i < seq_len; ++i) {
            // 提取单个序列元素（1,1,1,features）
            Tensor elem = create_tensor(1, 1, 1, features);
            for (int j = 0; j < features; ++j) {
                get_tensor_at(elem, 0, 0, 0, j) = get_tensor_at_const(seq, b, i, 0, j);
            }

            // 应用线性层
            Tensor elem_out;
            linear(elem, elem_out, params);

            // 保存结果到输出序列
            for (int j = 0; j < params.out_features; ++j) {
                get_tensor_at(out, b, i, 0, j) = get_tensor_at_const(elem_out, 0, 0, 0, j);
            }
        }
    }
}

// 自注意力计算（Transformer核心）
void self_attention(const Tensor& x, Tensor& out, const AttentionParams& params) {
    int n = x.n, c = x.c, h = x.h, w = x.w;
    int seq_len = h * w; // 特征图展平为序列长度
    // 1. 输入展平：NCHW → N, seq_len, 1, C（序列格式）
    Tensor x_seq = create_tensor(n, seq_len, 1, c);
    for (int b = 0; b < n; ++b) {
        int seq_idx = 0;
        for (int y = 0; y < h; ++y) {
            for (int x_ = 0; x_ < w; ++x_) {
                for (int ch = 0; ch < c; ++ch) {
                    get_tensor_at(x_seq, b, seq_idx, 0, ch) = get_tensor_at_const(x, b, ch, y, x_);
                }
                seq_idx++;
            }
        }
    }

    // 2. 计算Q、K、V（线性投影）
    Tensor Q, K, V;
    linear_sequence(x_seq, Q, params.q_params);
    linear_sequence(x_seq, K, params.k_params);
    linear_sequence(x_seq, V, params.v_params);

    // 3. 计算注意力权重：Q*K^T / sqrt(d_k)
    Tensor attn_weights = create_tensor(n, seq_len, 1, seq_len);
    float scale = 1.0f / sqrt(c);
    for (int b = 0; b < n; ++b) {
        for (int i = 0; i < seq_len; ++i) {
            // 计算Q×K^T
            for (int j = 0; j < seq_len; ++j) {
                float dot = 0.0f;
                for (int ch = 0; ch < c; ++ch) {
                    dot += get_tensor_at_const(Q, b, i, 0, ch) * get_tensor_at_const(K, b, j, 0, ch);
                }
                get_tensor_at(attn_weights, b, i, 0, j) = dot * scale;
            }

            // Softmax归一化（数值稳定版）
            float max_val = get_tensor_at_const(attn_weights, b, i, 0, 0);
            for (int j = 1; j < seq_len; ++j) {
                max_val = max(max_val, get_tensor_at_const(attn_weights, b, i, 0, j));
            }

            float exp_sum = 0.0f;
            for (int j = 0; j < seq_len; ++j) {
                float exp_val = exp(get_tensor_at_const(attn_weights, b, i, 0, j) - max_val);
                get_tensor_at(attn_weights, b, i, 0, j) = exp_val;
                exp_sum += exp_val;
            }

            for (int j = 0; j < seq_len; ++j) {
                get_tensor_at(attn_weights, b, i, 0, j) /= exp_sum;
            }
        }
    }

    // 4. 计算注意力输出：attn_weights * V
    Tensor attn_out = create_tensor(n, seq_len, 1, c);
    for (int b = 0; b < n; ++b) {
        for (int i = 0; i < seq_len; ++i) {
            for (int ch = 0; ch < c; ++ch) {
                float sum = 0.0f;
                for (int j = 0; j < seq_len; ++j) {
                    sum += get_tensor_at_const(attn_weights, b, i, 0, j) * get_tensor_at_const(V, b, j, 0, ch);
                }
                get_tensor_at(attn_out, b, i, 0, ch) = sum;
            }
        }
    }

    // 5. 输出线性层 + 残差连接
    Tensor linear_out;
    linear_sequence(attn_out, linear_out, params.out_params);
    for (int i = 0; i < linear_out.size; ++i) {
        linear_out.data[i] += x_seq.data[i];
    }

    // 6. 恢复维度：(N,seq_len,C) → (N,C,H,W)
    out = create_tensor(n, c, h, w);

    for (int b = 0; b < n; ++b) {
        int seq_idx = 0;
        for (int y = 0; y < h; ++y) {
            for (int x_ = 0; x_ < w; ++x_) {
                for (int ch = 0; ch < c; ++ch) {
                    get_tensor_at(out, b, ch, y, x_) = get_tensor_at_const(linear_out, b, seq_idx, 0, ch);
                }
                seq_idx++;
            }
        }
    }
}
