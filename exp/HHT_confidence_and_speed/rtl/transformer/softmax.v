module softmax(inputs,clk,enable,outputs,ackSoft);
parameter DATA_WIDTH=32;
localparam inputNum=10;
localparam INPUT_WIDTH = DATA_WIDTH*inputNum;
input [0:DATA_WIDTH*inputNum-1] inputs;
input clk;
input enable;
output reg [0:DATA_WIDTH*inputNum-1] outputs;
output reg ackSoft;

wire [DATA_WIDTH-1:0] expSum;
wire [DATA_WIDTH-1:0] expReciprocal;
wire [DATA_WIDTH-1:0] outMul;
wire [0:DATA_WIDTH*inputNum-1] exponents ;
wire [inputNum-1:0] acksExp; //acknowledge signals of exponents 
wire ackDiv; //ack signal of the division unit
wire expEnable;
wire divEnable;

reg enableDiv; //signal to enable division unit initially zero
reg [DATA_WIDTH-1:0] outExpReg;
reg [3:0] mulCounter;
reg [3:0] addCounter;

assign expEnable = enable && (ackSoft == 1'b0);
assign divEnable = enableDiv && (ackSoft == 1'b0);

genvar i;
generate
	for (i = 0; i < inputNum; i = i + 1) begin
		exponent #(.DATA_WIDTH(DATA_WIDTH)) exp (
		.x(inputs[DATA_WIDTH*i+:DATA_WIDTH]),
		.enable(expEnable),
		.clk(clk),
		.output_exp(exponents[DATA_WIDTH*i+:DATA_WIDTH]),
		.ack(acksExp[i]));
end
endgenerate

generate
	if (DATA_WIDTH == 32) begin : softmax_fp32
		floatAdd FADD1 (exponents[DATA_WIDTH*addCounter+:DATA_WIDTH],outExpReg,expSum);
		floatMult FM1 (exponents[DATA_WIDTH*mulCounter+:DATA_WIDTH],expReciprocal,outMul); // multiplication with reciprocal
	end
	else begin : softmax_fp16
		floatAdd16 FADD1 (exponents[DATA_WIDTH*addCounter+:DATA_WIDTH],outExpReg,expSum);
		floatMult16 FM1 (exponents[DATA_WIDTH*mulCounter+:DATA_WIDTH],expReciprocal,outMul); // multiplication with reciprocal
	end
endgenerate

floatReciprocal #(.DATA_WIDTH(DATA_WIDTH)) FR (.number(expSum),.clk(clk),.output_rec(expReciprocal),.ack(ackDiv),.enable(divEnable));

always @ (negedge clk) begin
	if(enable==1'b1) begin
		if(ackSoft==1'b0) begin 
			if(acksExp[0]==1'b1) begin //if the exponents finished
				if(enableDiv==1'b0) begin //division still did not start
					if(addCounter<4'b1001) begin
						addCounter=addCounter+1;
						outExpReg=expSum;
					end
					else begin
						enableDiv=1'b1;
					end
				end
				else if(ackDiv==1'b1) begin //check if the reciprocal is ready
					if(mulCounter<4'b1010) begin
						outputs[DATA_WIDTH*mulCounter+:DATA_WIDTH]=outMul;
						mulCounter=mulCounter+1;
					end
					else begin
						ackSoft=1'b1;
					end
				end
			end
		end
	end
	else begin
		//if enable is off reset all counters and acks
		mulCounter=4'b0000;
		addCounter=4'b0000;
		outExpReg={DATA_WIDTH{1'b0}};
		ackSoft=1'b0;
		enableDiv=1'b0;
	end
	
end

endmodule


 
