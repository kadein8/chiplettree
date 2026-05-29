`timescale 1ns/1ps
module top_tb();

parameter DATA_WIDTH = 16;
parameter ImgInW     = 32;
parameter ImgInH     = 32;
parameter Kernel     = 5;
parameter DepthC1    = 6;
parameter DepthC2    = 16;
parameter DepthC3    = 120;
parameter FC_2_out   = 10;

localparam IMAGE_WIDTH        = ImgInW*ImgInH*DATA_WIDTH;
localparam CONV1F_WIDTH       = Kernel*Kernel*DepthC1*DATA_WIDTH;
localparam CONV2F_WIDTH       = DepthC2*Kernel*Kernel*DepthC1*DATA_WIDTH;
localparam CONV3F_WIDTH       = DepthC3*Kernel*Kernel*DepthC2*DATA_WIDTH;
localparam CONVOUT_WIDTH      = DepthC3*DATA_WIDTH;
localparam FCOUT_WIDTH        = FC_2_out*DATA_WIDTH;
localparam IMAGE_WORDS        = ImgInW*ImgInH;
localparam PADDED_IMAGE_WORDS = 28*28;
localparam CONV1_WORDS        = Kernel*Kernel*DepthC1;
localparam CONV2_WORDS        = DepthC2*Kernel*Kernel*DepthC1;
localparam CONV3_WORDS        = DepthC3*Kernel*Kernel*DepthC2;
localparam CONV1_FILTER_WORDS = Kernel*Kernel;
localparam CONV2_FILTER_WORDS = Kernel*Kernel*DepthC1;
localparam CONV3_FILTER_WORDS = Kernel*Kernel*DepthC2;
localparam PERIOD             = 10;
localparam RESET_CYCLES       = 5;
localparam TIMEOUT_CYCLES     = 200000;

localparam CONV1_FILE = "CNN_V2/weight/filtersconv2d_1_IEEE16.txt";
localparam CONV2_FILE = "CNN_V2/weight/filtersconv2d_2_IEEE16.txt";
localparam CONV3_FILE = "CNN_V2/weight/filtersconv2d_3_IEEE16.txt";
localparam FC1_FILE   = "CNN_V2/weight/weightsdense_1_IEEE_fp16.txt";
localparam FC2_FILE   = "CNN_V2/weight/weightsdense_2_IEEE_fp16.txt";

reg clk;
reg reset;
reg  [0:IMAGE_WIDTH-1]  image;
reg  [0:CONV1F_WIDTH-1] Conv1F;
reg  [0:CONV2F_WIDTH-1] Conv2F;
reg  [0:CONV3F_WIDTH-1] Conv3F;
wire [0:FCOUT_WIDTH-1]  CNNoutput;

reg [DATA_WIDTH-1:0] image_mem [0:IMAGE_WORDS-1];
reg [CONV1F_WIDTH-1:0] conv1_raw_mem [0:0];
reg [DATA_WIDTH-1:0] conv2_mem [0:CONV2_WORDS-1];
reg [DATA_WIDTH-1:0] conv3_mem [0:CONV3_WORDS-1];
reg [IMAGE_WIDTH-1:0] image_default_raw;
reg [8*256-1:0] image_file;

integer image_fd;
integer output_fd;
integer cycle_count;
integer image_word_count;
integer scan_count;
integer skip_char;
integer idx;

task check_required_file;
    input [8*256-1:0] file_path;
    integer file_id;
    begin
        file_id = $fopen(file_path, "r");
        if (file_id == 0) begin
            $display("ERROR: failed to open required file: %0s", file_path);
            $finish;
        end
        else begin
            $fclose(file_id);
        end
    end
endtask

task load_default_image;
    integer word_idx;
    begin
        image_default_raw =
        16396'h00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000326638fd3bf038fd32460000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000032063b773be83be83be83b6f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000032c73b1f3bf03be83b7f3b4f3be833272606000000000000000000000000000000000000000000000000000000000000000000000000000000000000290533883b073be83bf03be83a5635453be83bf037a8000000000000000000000000000000000000000000000000000000000000000000000000000000000000391d3be83be83be83bf03be83be8360639ee3bf0393d0000000000000000000000000000000000000000000000000000000000000000000000000000000032663b773bf03bf039f637273bf03b2731e634f53c003945000000000000000000000000000000000000000000000000000000000000000000000000000032063b773be83be8399e2a0634b537982d45000000003bf03ba032460000000000000000000000000000000000000000000000000000000000000000000030c5392d3bf03b4f3a8735450000000000000000000000003bf03be8392d0000000000000000000000000000000000000000000000000000000000000000270739963be83b8834742cc52f070000000000000000000000003bf03be83a1e000000000000000000000000000000000000000000000000000000000000000033273be83be833e80000000000000000000000000000000000003bf03be83a1e00000000000000000000000000000000000000000000000000000000000000003a363bf039f600000000000000000000000000000000000000003c003bf03a2600000000000000000000000000000000000000000000000000000000000034c53bb83be8370700000000000000000000000000000000000000003bf03be838a500000000000000000000000000000000000000000000000000000000000035553be83b372e46000000000000000000000000000000002707383c3bf039d62a0600000000000000000000000000000000000000000000000000000000000035553be83aff000000000000000000000000000000002707381c3be83b0f3474000000000000000000000000000000000000000000000000000000000000000035553be8388d00000000000000000000000000003206392d3be8396d00000000000000000000000000000000000000000000000000000000000000000000000035653bf03b0f00000000000000000000000037273b773bf03915000000000000000000000000000000000000000000000000000000000000000000000000000035553be83bd0389532062f47355539963b0f3bf03aff393d3307000000000000000000000000000000000000000000000000000000000000000000000000000035553be83be83be83b2f3abf3be83be83be83a2638140000000000000000000000000000000000000000000000000000000000000000000000000000000000002f073a3e3be83be83bf03be83be83b4f388d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002e4638043be83bf03be8386c30a50000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        image = {IMAGE_WIDTH{1'b0}};
        for (word_idx = 0; word_idx < IMAGE_WORDS; word_idx = word_idx + 1) begin
            image[word_idx*DATA_WIDTH+:DATA_WIDTH] = image_default_raw[word_idx*DATA_WIDTH+:DATA_WIDTH];
        end
    end
endtask

task pack_loaded_image;
    integer word_idx;
    begin
        image = {IMAGE_WIDTH{1'b0}};
        for (word_idx = 0; word_idx < IMAGE_WORDS; word_idx = word_idx + 1) begin
            image[word_idx*DATA_WIDTH+:DATA_WIDTH] = image_mem[word_idx];
        end
    end
endtask

task pack_padded_28x28_image;
    integer row_idx;
    integer col_idx;
    integer src_idx;
    integer dst_idx;
    begin
        image = {IMAGE_WIDTH{1'b0}};
        for (row_idx = 0; row_idx < 28; row_idx = row_idx + 1) begin
            for (col_idx = 0; col_idx < 28; col_idx = col_idx + 1) begin
                src_idx = row_idx*28 + col_idx;
                dst_idx = (row_idx+2)*ImgInW + (col_idx+2);
                image[dst_idx*DATA_WIDTH+:DATA_WIDTH] = image_mem[src_idx];
            end
        end
    end
endtask

task pack_conv1_filters;
    integer filter_idx;
    integer word_idx;
    integer src_word_idx;
    integer dst_word_idx;
    begin
        Conv1F = {CONV1F_WIDTH{1'b0}};
        for (filter_idx = 0; filter_idx < DepthC1; filter_idx = filter_idx + 1) begin
            for (word_idx = 0; word_idx < CONV1_FILTER_WORDS; word_idx = word_idx + 1) begin
                dst_word_idx = filter_idx*CONV1_FILTER_WORDS + word_idx;
                src_word_idx = (DepthC1-1-filter_idx)*CONV1_FILTER_WORDS + word_idx;
                Conv1F[dst_word_idx*DATA_WIDTH+:DATA_WIDTH] =
                    conv1_raw_mem[0][src_word_idx*DATA_WIDTH+:DATA_WIDTH];
            end
        end
    end
endtask

task pack_conv2_filters;
    integer filter_idx;
    integer word_idx;
    integer src_word_idx;
    integer dst_word_idx;
    begin
        Conv2F = {CONV2F_WIDTH{1'b0}};
        for (filter_idx = 0; filter_idx < DepthC2; filter_idx = filter_idx + 1) begin
            for (word_idx = 0; word_idx < CONV2_FILTER_WORDS; word_idx = word_idx + 1) begin
                dst_word_idx = filter_idx*CONV2_FILTER_WORDS + word_idx;
                src_word_idx = filter_idx*CONV2_FILTER_WORDS + (CONV2_FILTER_WORDS-1-word_idx);
                Conv2F[dst_word_idx*DATA_WIDTH+:DATA_WIDTH] = conv2_mem[src_word_idx];
            end
        end
    end
endtask

task pack_conv3_filters;
    integer filter_idx;
    integer word_idx;
    integer src_word_idx;
    integer dst_word_idx;
    begin
        Conv3F = {CONV3F_WIDTH{1'b0}};
        for (filter_idx = 0; filter_idx < DepthC3; filter_idx = filter_idx + 1) begin
            for (word_idx = 0; word_idx < CONV3_FILTER_WORDS; word_idx = word_idx + 1) begin
                dst_word_idx = filter_idx*CONV3_FILTER_WORDS + word_idx;
                src_word_idx = filter_idx*CONV3_FILTER_WORDS + (CONV3_FILTER_WORDS-1-word_idx);
                Conv3F[dst_word_idx*DATA_WIDTH+:DATA_WIDTH] = conv3_mem[src_word_idx];
            end
        end
    end
endtask

CNN_top #(
    .DATA_WIDTH(DATA_WIDTH),
    .ImgInW(ImgInW),
    .ImgInH(ImgInH),
    .Kernel(Kernel),
    .DepthC1(DepthC1),
    .DepthC2(DepthC2),
    .DepthC3(DepthC3),
    .FC_2_out(FC_2_out)
) uut (
    .clk(clk),
    .reset(reset),
    .image(image),
    .Conv1F(Conv1F),
    .Conv2F(Conv2F),
    .Conv3F(Conv3F),
    .CNNoutput(CNNoutput)
);

defparam uut.FCPart.W1.file = FC1_FILE;
defparam uut.FCPart.W2.file = FC2_FILE;

always #(PERIOD/2) clk = ~clk;

always @(posedge clk) begin
    cycle_count = cycle_count + 1;
end

initial begin
    clk = 1'b0;
    reset = 1'b1;
    cycle_count = 0;
    image = {IMAGE_WIDTH{1'b0}};
    Conv1F = {CONV1F_WIDTH{1'b0}};
    Conv2F = {CONV2F_WIDTH{1'b0}};
    Conv3F = {CONV3F_WIDTH{1'b0}};
    image_word_count = 0;
    image_file = "CNN_V2/weight/input_image_fp16.hex";

    if ($value$plusargs("IMAGE_FILE=%s", image_file)) begin
        $display("INFO: using image file from plusarg: %0s", image_file);
    end
    else begin
        $display("INFO: no IMAGE_FILE plusarg found, trying default image file: %0s", image_file);
    end

    $dumpfile("top_tb.vcd");
    $dumpvars(0, top_tb);

    check_required_file(CONV1_FILE);
    check_required_file(CONV2_FILE);
    check_required_file(CONV3_FILE);
    check_required_file(FC1_FILE);
    check_required_file(FC2_FILE);

    $readmemh(CONV1_FILE, conv1_raw_mem);
    $readmemh(CONV2_FILE, conv2_mem);
    $readmemh(CONV3_FILE, conv3_mem);

    pack_conv1_filters();
    pack_conv2_filters();
    pack_conv3_filters();

    image_fd = $fopen(image_file, "r");
    if (image_fd != 0) begin
        image_word_count = 0;
        while (!$feof(image_fd) && image_word_count < IMAGE_WORDS) begin
            scan_count = $fscanf(image_fd, "%h", image_mem[image_word_count]);
            if (scan_count == 1) begin
                image_word_count = image_word_count + 1;
            end
            else if (!$feof(image_fd)) begin
                skip_char = $fgetc(image_fd);
            end
        end
        $fclose(image_fd);
    end

    if (image_word_count == IMAGE_WORDS) begin
        $display("INFO: loaded %0d image words from %0s", image_word_count, image_file);
        pack_loaded_image();
    end
    else if (image_word_count == PADDED_IMAGE_WORDS) begin
        $display("INFO: loaded %0d image words from %0s and padded to 32x32", image_word_count, image_file);
        pack_padded_28x28_image();
    end
    else begin
        $display("INFO: image file unavailable or unsupported word count (%0d), using built-in default image stimulus", image_word_count);
        load_default_image();
    end

    repeat (RESET_CYCLES) @(posedge clk);
    reset = 1'b0;
end

initial begin
    wait (reset == 1'b0);
    wait (uut.FCPart.DoneFlag == 1'b1);
    #(PERIOD);

    output_fd = $fopen("top_tb_output.txt", "w");
    $display("INFO: top_tb finished at cycle %0d", cycle_count);

    for (idx = 0; idx < FC_2_out; idx = idx + 1) begin
        $display("CNNoutput[%0d] = %h", idx, CNNoutput[idx*DATA_WIDTH+:DATA_WIDTH]);
        if (output_fd != 0) begin
            $fwrite(output_fd, "CNNoutput[%0d] = %h\n", idx, CNNoutput[idx*DATA_WIDTH+:DATA_WIDTH]);
        end
    end

    if (output_fd != 0) begin
        $fclose(output_fd);
    end

    $finish;
end

initial begin
    wait (reset == 1'b0);
    repeat (TIMEOUT_CYCLES) @(posedge clk);
    $display("ERROR: top_tb timeout after %0d cycles", cycle_count);
    $finish;
end

endmodule
