`include "npu.vh"

// -----------------------------------------------------------------------------
// fifo.sv  --  SYNTHESIZABLE replacement (Vivado) for the Quartus scfifo version
//
// Same module names, parameters and ports as the original (fifo, showahead_fifo,
// mlab_fifo, normal_fifo, asym_fifo), so the rest of the NPU RTL is unchanged.
// The Intel scfifo IP (and its defparams) is replaced by one inferred core,
// fifo_core, which maps to block RAM (or distributed RAM for the small mlab FIFO).
//
// Behaviour kept from the original:
//   * wr_ok   = ~almost_full      (almost_full when usedw >= almost-full value)
//   * rd_ok   = ~empty
//   * overflow / underflow checking ON: writes to a full FIFO and reads from an
//     empty FIFO are ignored
//   * sclr (rst) is a synchronous clear
//   * show-ahead FIFOs present the head word on rd_data without a read; rd_en pops it
//   * normal_fifo (show-ahead OFF): rd_data is valid ONE cycle after rd_en
//   * usedw is the low AW bits of the occupancy (wraps to 0 when a power-of-2
//     FIFO is completely full, like the Intel core)
// TARGET_FPGA is kept only so existing instantiations still elaborate.
// -----------------------------------------------------------------------------

// ----------------------------------------------------------------- core
module fifo_core #(
	parameter DW         = 32,
	parameter DEPTH      = 512,
	parameter AW         = $clog2(DEPTH),
	parameter SHOWAHEAD  = 1,           // 1: first-word-fall-through, 0: registered read
	parameter AFV        = DEPTH - 2,   // almost_full asserted when count >= AFV
	parameter USE_BRAM   = 1            // 1: block RAM, 0: distributed (LUT) RAM
) (
	input            clk,
	input            rst,
	input            wr_en,
	input  [DW-1:0]  wr_data,
	input            rd_en,
	output [DW-1:0]  rd_data,
	output           empty,
	output           full,
	output           almost_full,
	output [AW-1:0]  usedw,
	output           nonempty_nxt     // FIFO will be non-empty next cycle
);
	localparam CW = $clog2(DEPTH+1);

	reg [AW-1:0] wptr, rptr;
	reg [CW-1:0] count;

	assign empty       = (count == 0);
	assign full        = (count == DEPTH);
	assign almost_full = (count >= AFV);
	assign usedw       = count[AW-1:0];

	wire do_wr = wr_en && !full;
	wire do_rd = rd_en && !empty;
	wire [CW:0] count_nxt = count + do_wr - do_rd;
	assign nonempty_nxt = (count_nxt != 0);

	wire [AW-1:0] wptr_nxt = (wptr == DEPTH-1) ? {AW{1'b0}} : wptr + 1'b1;
	wire [AW-1:0] rptr_nxt = (rptr == DEPTH-1) ? {AW{1'b0}} : rptr + 1'b1;

	always @(posedge clk) begin
		if (rst) begin
			wptr  <= {AW{1'b0}};
			rptr  <= {AW{1'b0}};
			count <= {CW{1'b0}};
		end else begin
			if (do_wr) wptr <= wptr_nxt;
			if (do_rd) rptr <= rptr_nxt;
			count <= count + do_wr - do_rd;
		end
	end

	reg [DW-1:0] rd_q;
	assign rd_data = rd_q;

	// read address: for show-ahead, look one word ahead when a pop happens
	wire [AW-1:0] raddr = (SHOWAHEAD != 0) ? (do_rd ? rptr_nxt : rptr) : rptr;

	generate
		if (USE_BRAM != 0) begin : g_bram
			(* ram_style = "block" *) reg [DW-1:0] mem [0:DEPTH-1];
			always @(posedge clk) if (do_wr) mem[wptr] <= wr_data;
			if (SHOWAHEAD != 0) begin : g_sa
				// bypass: a word written this cycle may be the one being fetched
				always @(posedge clk)
					rd_q <= (do_wr && (wptr == raddr)) ? wr_data : mem[raddr];
			end else begin : g_std
				always @(posedge clk) if (do_rd) rd_q <= mem[rptr];
			end
		end else begin : g_dist
			(* ram_style = "distributed" *) reg [DW-1:0] mem [0:DEPTH-1];
			always @(posedge clk) if (do_wr) mem[wptr] <= wr_data;
			if (SHOWAHEAD != 0) begin : g_sa
				always @(posedge clk)
					rd_q <= (do_wr && (wptr == raddr)) ? wr_data : mem[raddr];
			end else begin : g_std
				always @(posedge clk) if (do_rd) rd_q <= mem[rptr];
			end
		end
	endgenerate
endmodule

// ----------------------------------------------------------------- fifo
// Show-ahead FIFO. rd_en is an acknowledgement (queue pop).
module fifo # (
	parameter DW    = 1280,   // FIFO data width
	parameter DEPTH = 512,    // FIFO depth
	parameter ID    = 0,      // Unique FIFO ID (used for debugging)
	parameter TARGET_FPGA = `TARGET_FPGA,
	parameter AW    = $clog2(DEPTH)
) (
	input           clk,
	input           rst,
	input           wr_en,
	input  [DW-1:0] wr_data,
	output          wr_ok,
	input           rd_en,
	output [DW-1:0] rd_data,
	output          rd_ok,
	output [AW-1:0] usedw
);
	wire empty, full, almost_full;

	fifo_core #(
		.DW(DW), .DEPTH(DEPTH), .AW(AW),
		.SHOWAHEAD(1), .AFV(DEPTH-10), .USE_BRAM(1)
	) core (
		.clk(clk), .rst(rst),
		.wr_en(wr_en), .wr_data(wr_data),
		.rd_en(rd_en), .rd_data(rd_data),
		.empty(empty), .full(full), .almost_full(almost_full),
		.usedw(usedw), .nonempty_nxt()
	);

	assign rd_ok = ~empty;
	assign wr_ok = ~almost_full;
endmodule

// ------------------------------------------------------- showahead_fifo
// Block-RAM FIFO followed by a small (7-deep) LUT-RAM FIFO that provides the
// show-ahead output.
module showahead_fifo # (
	parameter DW    = 1280,   // FIFO data width
	parameter DEPTH = 512,    // FIFO depth
	parameter ID    = 0,      // Unique FIFO ID (used for debugging)
	parameter TARGET_FPGA = `TARGET_FPGA,
	parameter AW    = $clog2(DEPTH),
	parameter MLAB_FIFO_DEPTH = 7,
	parameter MLAB_FIFO_ADDRW = $clog2(MLAB_FIFO_DEPTH)
) (
	input           clk,
	input           rst,
	input           wr_en,
	input  [DW-1:0] wr_data,
	output          wr_ok,
	input           rd_en,
	output [DW-1:0] rd_data,
	output          rd_ok,
	output [MLAB_FIFO_ADDRW-1:0] usedw
);

	wire mlab_fifo_wr_ok;
	wire [DW-1:0] m20k_fifo_rd_data;
	reg rd_from_m20k, r_rd_from_m20k;

	// Block-RAM FIFO (show-ahead OFF: data is valid one cycle after rd_from_m20k).
	// The core is used directly so we can see whether the FIFO will still hold data
	// next cycle. rd_from_m20k is registered, so without this a read request issued
	// for the last word would be repeated on an empty FIFO and duplicate the word.
	wire m20k_empty, m20k_full, m20k_almost_full, m20k_nonempty_nxt;
	wire [AW-1:0] m20k_usedw_unused;

	fifo_core # (
		.DW 		(DW),
		.DEPTH 		(DEPTH),
		.AW 		(AW),
		.SHOWAHEAD 	(0),
		.AFV 		(DEPTH-2),
		.USE_BRAM 	(1)
	) m20k_fifo (
		.clk 		(clk),
		.rst 		(rst),
		.wr_en 		(wr_en),
		.wr_data 	(wr_data),
		.rd_en 		(rd_from_m20k),
		.rd_data 	(m20k_fifo_rd_data),
		.empty 		(m20k_empty),
		.full 		(m20k_full),
		.almost_full(m20k_almost_full),
		.usedw 		(m20k_usedw_unused),
		.nonempty_nxt(m20k_nonempty_nxt)
	);
	assign wr_ok = ~m20k_almost_full;

	mlab_fifo # (
		.DW 		(DW),
		.DEPTH 		(MLAB_FIFO_DEPTH),
		.ID 		(ID),
		.TARGET_FPGA(TARGET_FPGA),
		.AW 		(MLAB_FIFO_ADDRW)
	) mlab_fifo (
		.clk 		(clk),
		.rst 		(rst),
		.wr_en 		(r_rd_from_m20k),
		.wr_data 	(m20k_fifo_rd_data),
		.wr_ok 		(mlab_fifo_wr_ok),
		.rd_en 		(rd_en),
		.rd_data 	(rd_data),
		.rd_ok 		(rd_ok),
		.usedw 		(usedw)
	);

	always @ (posedge clk) begin
		if (rst) begin
			rd_from_m20k <= 1'b0;
			r_rd_from_m20k <= 1'b0;
		end else begin
			rd_from_m20k <= m20k_nonempty_nxt && mlab_fifo_wr_ok;
			r_rd_from_m20k <= rd_from_m20k;
		end
	end

endmodule

// ------------------------------------------------------------ mlab_fifo
// Small show-ahead FIFO in distributed (LUT) RAM.
module mlab_fifo # (
	parameter DW    = 1280,   // FIFO data width
	parameter DEPTH = 512,    // FIFO depth
	parameter ID    = 0,      // Unique FIFO ID (used for debugging)
	parameter TARGET_FPGA = `TARGET_FPGA,
	parameter AW    = $clog2(DEPTH)
) (
	input           clk,
	input           rst,
	input           wr_en,
	input  [DW-1:0] wr_data,
	output          wr_ok,
	input           rd_en,
	output [DW-1:0] rd_data,
	output          rd_ok,
	output [AW-1:0] usedw
);
	wire empty, full, almost_full;

	fifo_core #(
		.DW(DW), .DEPTH(DEPTH), .AW(AW),
		.SHOWAHEAD(1), .AFV(DEPTH-2), .USE_BRAM(0)
	) core (
		.clk(clk), .rst(rst),
		.wr_en(wr_en), .wr_data(wr_data),
		.rd_en(rd_en), .rd_data(rd_data),
		.empty(empty), .full(full), .almost_full(almost_full),
		.usedw(usedw), .nonempty_nxt()
	);

	assign rd_ok = ~empty;
	assign wr_ok = ~almost_full;
endmodule

// ----------------------------------------------------------- normal_fifo
// Block-RAM FIFO, show-ahead OFF: rd_data is valid one cycle after rd_en.
module normal_fifo # (
	parameter DW    = 1280,   // FIFO data width
	parameter DEPTH = 512,    // FIFO depth
	parameter ID    = 0,      // Unique FIFO ID (used for debugging)
	parameter TARGET_FPGA = `TARGET_FPGA,
	parameter AW    = $clog2(DEPTH)
) (
	input           clk,
	input           rst,
	input           wr_en,
	input  [DW-1:0] wr_data,
	output          wr_ok,
	input           rd_en,
	output [DW-1:0] rd_data,
	output          rd_ok
);
	wire empty, full, almost_full;
	wire [AW-1:0] usedw_unused;

	fifo_core #(
		.DW(DW), .DEPTH(DEPTH), .AW(AW),
		.SHOWAHEAD(0), .AFV(DEPTH-2), .USE_BRAM(1)
	) core (
		.clk(clk), .rst(rst),
		.wr_en(wr_en), .wr_data(wr_data),
		.rd_en(rd_en), .rd_data(rd_data),
		.empty(empty), .full(full), .almost_full(almost_full),
		.usedw(usedw_unused), .nonempty_nxt()
	);

	assign rd_ok = ~empty;
	assign wr_ok = ~almost_full;
endmodule

// ------------------------------------------------------------- asym_fifo
// Show-ahead asymmetric FIFO built on the 'fifo' above.
// The input data width has to be a multiple of the output data width.
module asym_fifo # (
	parameter IDW   = 1280,   // FIFO input data width
	parameter ODW   = 1280,   // FIFO output data width
	parameter DEPTH = 512,    // FIFO depth
	parameter ID    = 0,      // Unique FIFO ID (used for debugging)
	parameter AW    = $clog2(DEPTH),
	parameter SELW  = `max($clog2(IDW/ODW),1)
) (
	input            clk,
	input            rst,
	input            wr_en,
	input  [IDW-1:0] wr_data,
	output           wr_ok,
	input            rd_en,
	output [ODW-1:0] rd_data, 
	output           rd_ok,
	output [AW-1:0]  usedw
);

	wire fifo_wr_ok, fifo_wr_en;
	wire fifo_rd_ok;
	reg  fifo_rd_en;
	wire [IDW-1:0] fifo_wr_data;
	wire [IDW-1:0] fifo_rd_data;

	fifo # (
		.ID       (ID), 
		.DW       (IDW), 
		.DEPTH    (DEPTH)
	) fifo (
		.clk      (clk), 
		.rst      (rst),
		.wr_en    (fifo_wr_en  ),
		.wr_data  (fifo_wr_data),
		.wr_ok    (fifo_wr_ok  ),
		.rd_ok    (fifo_rd_ok  ),
		.rd_data  (fifo_rd_data),
		.rd_en    (fifo_rd_en  ),
		.usedw    (usedw)
	);

	// fetch and keep actual queue's outputs
	reg [IDW-1:0] rd_data_reg, rd_data_reg_nxt;
	reg rd_ok_reg, rd_ok_reg_nxt;
	// keep track of a current position
	reg [SELW-1:0] rd_data_sel, rd_data_sel_nxt;

	// simple state machine
	always @(*) begin
		rd_ok_reg_nxt     = rd_ok_reg;
		rd_data_reg_nxt   = rd_data_reg;
		rd_data_sel_nxt   = rd_data_sel;
		fifo_rd_en        = 0;
		// initial state
		if (~rd_ok_reg) begin
			if (fifo_rd_ok) begin 
				// fetch a new value from fifo & initialize a counter
				rd_ok_reg_nxt     = 1'b1;
				rd_data_reg_nxt   = fifo_rd_data;
				rd_data_sel_nxt   = 0;
				// increment rd_ptr in the actural fifo queue
				fifo_rd_en        = 1;
			end
		end else begin // dequeue state
			if (rd_en) begin
				if (rd_data_sel == (IDW/ODW) - 1) begin
					// initialize a counter & go bakc to the initial state
					rd_ok_reg_nxt   = 1'b0;
					rd_data_sel_nxt = 0;
				end else begin
					// forward a bit selector
					rd_ok_reg_nxt   = 1'b1;
					rd_data_reg_nxt = rd_data_reg >> ODW;
					rd_data_sel_nxt = rd_data_sel + 1'b1;
				end
			end
		end
	end

	always @(posedge clk) begin
		if (rst) begin
			rd_ok_reg <= 0;
		end else begin
			rd_ok_reg <= rd_ok_reg_nxt;
		end
		rd_data_reg <= rd_data_reg_nxt;
		rd_data_sel <= rd_data_sel_nxt;
	end

	// connect top-level outputs
	assign rd_ok = rd_ok_reg;
	assign rd_data = rd_data_reg[ODW-1:0];
	assign wr_ok = fifo_wr_ok;
	assign fifo_wr_data = wr_data;
	assign fifo_wr_en = wr_en;

endmodule
