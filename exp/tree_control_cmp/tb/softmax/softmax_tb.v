// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : softmax_tb.v
// Create : 2023-11-26 17:57:50
// Revise : 2023-11-26 17:57:50
// Description : softmax tb
// -----------------------------------------------------------------------------
`timescale 1ps/1ps
module softmax_tb();
localparam DATA_WIDTH=32;
localparam inputNum=10;
reg [DATA_WIDTH*inputNum-1:0] inputs;
reg clk;
reg enable;
wire [DATA_WIDTH*inputNum-1:0] outputs1;
wire [DATA_WIDTH*inputNum-1:0] outputs2;
wire [DATA_WIDTH*inputNum-1:0] outputs3;


wire ackSoft1;
wire ackSoft2;
wire ackSoft3;


wire [31:0] result1;
wire [31:0] result2;
wire [31:0] result3;

softmax #(.DATA_WIDTH(DATA_WIDTH)) soft(inputs,clk,enable,outputs1,ackSoft1);
softmax_1 #(.DATA_WIDTH(DATA_WIDTH)) soft1(inputs,clk,enable,outputs2,ackSoft2);
softmax_2 #(.DATA_WIDTH(DATA_WIDTH)) soft2(inputs,clk,enable,outputs3,ackSoft3);


localparam PERIOD = 100;
integer count;

assign result1 = outputs1 >> (32*(count-1));
assign result2 = outputs2 >> (32*(count-1));
assign result3 = outputs3 >> (32*(count-1));






always 
	#(PERIOD/2) clk = ~clk;

initial begin
	clk=1'b1;
	inputs=320'b00111110010011001100110011001101_10111110010011001100110011001101_00111111100110011001100110011010_00111111101001100110011001100110_10111111011001100110011001100110_00111110100110011001100110011010_01000000010001100110011001100110_10111100101000111101011100001010_00111111100011100001010001111011_00111110101001010110000001000010;
	//inputs are 0.2 -0.2 1.2 1.3 -0.9 0.3 3.1 -0.02 1.11 0.323
	count=1;
	enable=1'b0;
	#(PERIOD);
	enable=1'b1;
	
	while(ackSoft1!=1'b1) begin
		#(PERIOD);		
	end
	//outputs are 0.03255, 0.02182, 0.08847, 0.09776, 0.0108, 0.0359, 0.5687,  0.02612, 0.0808, 0.03681

    #(15*PERIOD);

	inputs=320'b00111111001100001010001111010111_10111110010011001100110011001101_00111111100110011001100110011010_00111111101001100110011001100110_10111111011001100110011001100110_00111110100110011001100110011010_01000000010001100110011001100110_10111100101000111101011100001010_00111111100011100001010001111011_00111110101001010110000001000010;
	//inputs are 0.69 -0.2 1.2 1.3 -0.9 0.3 3.1 -0.02 1.11 0.323
    
	enable=1'b0;
	#(10*PERIOD);
	enable=1'b1;
	while(ackSoft1!=1'b1) begin
		#(PERIOD);
	end


    #(10*PERIOD);
    $stop();
    

    //outputs are 0.05207118 0.0213835  0.0866926  0.09579553 0.01062096 0.03525543 0.5572659  0.0256007  0.07923851 0.0360757
    

    
 										
end


always@(posedge clk)begin

    if(count == 'd10 || (ackSoft1 == 1'b0 && ackSoft2 == 1'b0 && ackSoft3 == 1'b0) )begin
        count=1  ;
    end
    else if (ackSoft1 == 1'b1 && ackSoft2 == 1'b1 && ackSoft3 == 1'b1)begin
        count=count+1;
    end
end

always@(*) begin
    if(ackSoft1 ==1'b1) begin
        $display("softmax1 finished!",$time);
    end 
end

always@(*) begin
    if(ackSoft2 ==1'b1) begin
        $display("softmax2 finished!",$time);
    end 
end

always@(*) begin
    if(ackSoft3 ==1'b1) begin
        $display("softmax3 finished!",$time);
    end 
end




endmodule
