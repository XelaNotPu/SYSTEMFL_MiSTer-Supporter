// SPDX-License-Identifier: GPL-3.0-or-later
// Sequential i960KA bring-up implementation. See docs/CPU.md for limitations.
// Bus: aligned byte address, little-endian data, byte strobes. Hold request
// and payload until ready; slave must complete each request exactly once.
module i960ka (
    input wire clk, reset, pause,
    input wire [3:0] irq,
    output reg req, output reg write,
    output reg [31:0] addr, wdata, input wire [31:0] rdata,
    // The word's whole aligned 16-byte block and whether it is meaningful (SDRAM read): an
    // instruction-cache miss fills all four words of the block, not just the missed one.
    input wire [127:0] rdata_wide, input wire rdata_wide_valid,
    output reg [3:0] be, input wire ready,
    // DEVELOPMENT performance counters (FLP1 probe): bus-wait cycles, instruction-fetch reads,
    // data reads, data writes, call-frame stores, read-buffer hits.
    output reg [31:0] perf_wait, perf_ifetch, perf_data_rd, perf_data_wr, perf_frames, perf_dbuf_hit,
    output reg halted,
    output reg [31:0] debug_pc, debug_opcode,
    output reg retired,
    output wire [31:0] debug_ac,
    output wire [31:0] debug_process_control,
    input wire [4:0] debug_reg_addr, output wire [31:0] debug_reg_data
);
    reg [31:0] r[0:31];
    // Share one variable-address write port across ALU/load/move operations.
    // These blocking temporaries describe combinational writeback selection;
    // register state still changes only through the final nonblocking write.
    reg register_write;
    reg [4:0] register_index;
    reg [31:0] register_value;
    reg [31:0] move_values[0:3];
    reg [63:0] multiply_acc,multiply_shift;
    reg [31:0] multiply_bits,divide_q,divide_r,divide_by;
    reg [4:0] arithmetic_count;
    reg arithmetic_pair,divide_signed,divide_negative_q,divide_negative_r;
    reg [1:0] divide_result; // quotient, remainder, modulo
    wire [63:0] multiply_sum=multiply_acc+(multiply_bits[0] ? multiply_shift : 64'd0);
    wire [32:0] divide_trial={divide_r,divide_q[31]};
    wire divide_subtract=divide_trial>={1'b0,divide_by};
    wire [32:0] divide_next_r=divide_subtract ? divide_trial-{1'b0,divide_by} : divide_trial;
    wire [31:0] divide_next_q={divide_q[30:0],divide_subtract};
    task write_register(input [4:0] index,input [31:0] data);
        begin register_write=1; register_index=index; register_value=data; end
    endtask
    // Direct-mapped 1 KiB instruction cache. Tags/data have synchronous reads
    // and infer block RAM; only validity resets. Data writes invalidate a
    // matching instruction word, and bank swaps/IAC invalidate all words.
    reg [31:0] instruction_cache[0:255];
    reg [21:0] instruction_tags[0:255];
    reg [255:0] instruction_valid;
    reg [31:0] cached_instruction;
    reg [21:0] cached_tag;
    reg cached_valid;
    // Block fill: the three other words of the missed 16-byte block are written into the
    // cache in the background, one per cycle, while decoding proceeds. Measured on hardware
    // (2026-09-23, FLP0 probe) the i960 ran at 3.6 MIPS with 0.83 SDRAM transactions per
    // instruction (~14 clk each): single-word fills and an uncached displacement word made the
    // game run at ~52% speed even with the CPU winning 81% of all SDRAM grants.
    reg [127:0] bus_value_wide, fill_data;
    reg bus_wide_ok;
    reg [27:0] fill_base;
    reg [3:0] fill_pending;
    // Single write port for the cache data/tag RAMs (every site issues through these; a second
    // write site turned the cache into 37k ALUTs of logic). The write lands one cycle after
    // issue; the valid bit is set at issue, which is safe because the earliest cache read of
    // that index is at least two cycles later.
    // One-block read buffer: the last 16-byte block returned by SDRAM (any read). A read
    // inside it completes without a bus transaction; a write into the block invalidates it.
    // No other master writes the SDRAM regions the i960 reads through this path.
    // Local register frame cache (the i960's on-chip register sets, 4 frames, LIFO): a call
    // copies r0-r15 into the cache (16 cycles) instead of 16 SDRAM stores and a return restores
    // them from it instead of 16 loads. Frames reach memory only when the cache overflows (the
    // oldest is spilled), on flushreg, or when the frame being returned to is not the cached
    // top (a stack switch: everything is spilled, then the memory path is used).
    (* ramstyle = "MLAB" *) reg [31:0] fcache[0:63];   // {slot, register}
    reg [25:0] fcache_tag[0:3];                          // frame base >> 6
    reg [2:0] fcount;                                    // cached frames, 0..4
    reg [1:0] ftop;                                      // next free slot; top = ftop-1
    reg [1:0] fslot;
    reg [31:0] fcache_q;
    reg [5:0] spill_then;
    wire [1:0] foldest = ftop - fcount[1:0];
    always @(posedge clk) fcache_q <= fcache[{fslot,count[3:0]}];
    reg [127:0] dbuf;
    reg [27:0] dbuf_base;
    reg dbuf_valid;
    reg [1:0] dbuf_sel;   // word of the buffer a hit selects, consumed in DBUF_HIT (one mux site:
                          // selecting inside the inlined task cost a 78:1 x 128-bit mux, 6,656 LEs)
    reg cache_we;
    reg [7:0] cache_waddr;
    reg [31:0] cache_wdata;
    reg [21:0] cache_wtag;
    always @(posedge clk) if (cache_we) begin
        instruction_cache[cache_waddr]<=cache_wdata;
        instruction_tags[cache_waddr]<=cache_wtag;
    end
    always @(posedge clk) begin
        cached_instruction<=instruction_cache[ip[9:2]];
        cached_tag<=instruction_tags[ip[9:2]];
        cached_valid<=instruction_valid[ip[9:2]];
    end
    reg [31:0] ip, ir, sat, prcb, ac, pc, icr;
    wire [31:0] ext_addr = ip - 32'd4;   // address of the displacement word just fetched (EA_EXT_FILL)
    reg [31:0] ea, mem_value, call_target, frame_base, new_frame;
    reg [31:0] syn_src, syn_dst, syn_data[0:3];
    reg [3:0] irq_previous, irq_pending, irq_pop;
    reg [7:0] irq_latched_vector[0:3];
    reg [7:0] irq_vector;
    reg [4:0] irq_level;
    reg [31:0] irq_table, pending_levels, saved_process_control;
    reg call_irq, check_irqs, return_irq;
    reg selected_valid;
    reg [1:0] selected_line;
    reg [7:0] selected_vector;
    integer q;
    always @* begin
        selected_valid=0; selected_line=0; selected_vector=0;
        for(integer n=0;n<4;n=n+1) begin
            if(irq_pending[n] && (!selected_valid || irq_latched_vector[n]>selected_vector)) begin
                selected_valid=1; selected_line=n[1:0]; selected_vector=irq_latched_vector[n];
            end
        end
    end
    // External board lines remain asserted until a system-register ACK. Latch
    // rising edges even during memory stalls, and do not retrigger held lines.
    always @(posedge clk) begin
        if(reset) begin
            irq_previous<=0; irq_pending<=0;
            for(q=0;q<4;q=q+1) irq_latched_vector[q]<=0;
        end else begin
            irq_previous<=irq;
            irq_pending<=(irq_pending & ~irq_pop) | (irq & ~irq_previous);
            for(q=0;q<4;q=q+1)
                if(irq[q] && !irq_previous[q]) irq_latched_vector[q]<=icr[8*q+:8];
        end
    end
    reg [4:0] transfer_reg;
    reg [4:0] count, total;
    reg [2:0] bytes;
    reg mem_write, sign_extend;
    reg split_access;
    reg [31:0] split_low;
    reg [31:0] bus_value;
    reg [5:0] state, resume_state;
    localparam BOOT=0, SAT=1, PRCB=2, IP=3, STACK=4, FETCH=5,
        DECODE=6, EA_EXT=7, MEMORY=8, MEM_DONE=9, WAIT_BUS=10,
        CALL_SAVE=11, CALL_NEXT=12, CALL_FINISH=13,
        RET_LOAD=14, RET_NEXT=15, RET_FINISH=16,
        SYN_LOAD=17, SYN_NEXT=18, SYN_EXEC=19, SYN_WRITE=20,
        SYN_WNEXT=21, IAC_STORE=22, IAC_STORE2=23,
        IRQ_TABLE=26, IRQ_STACK=27, IRQ_VECTOR=28,
        IRQ_SAVE_PC=29, IRQ_SAVE_AC=30, IRQ_SAVE_VECTOR=31, IRQ_ENTER=32,
        IRQ_PEND_LEVEL=33, IRQ_PEND_ADDR=34, IRQ_PEND_WORD=35,
        IRQ_CHECK_TABLE=36, IRQ_CHECK_LEVEL=37, IRQ_CHECK_WORD=38,
        IRQ_CLEAR_LEVEL=39, IRQ_DISPATCH=40, RET_PC=41, RET_AC=42, ICACHE_CHECK=43, MOVE_MULTI=44, MULTIPLY=45, DIVIDE=46, DIVIDE_FINISH=47,
        EA_EXT_FILL=48, DBUF_HIT=49,
        FC_ALLOC=50, FC_ALLOC2=51, FC_SAVE=52, FC_SPILL_RD=53, FC_SPILL_WR=54, FC_SPILL_NEXT=55,
        FC_RET=56, FC_LOAD_RD=57, FC_LOAD_WR=58, FC_FLUSH=59;
    wire [7:0] op = ir[31:24];
    wire [3:0] subop = ir[10:7];
    wire [4:0] dst = ir[23:19];
    wire [31:0] s1 = ir[11] ? {27'd0,ir[4:0]} : r[ir[4:0]];
    wire [31:0] s2 = ir[12] ? {27'd0,ir[18:14]} : r[ir[18:14]];
    wire [31:0] c1 = ir[13] ? {27'd0,dst} : r[dst];
    wire [31:0] c2 = r[ir[18:14]];
    wire [31:0] branch = debug_pc + {{8{ir[23]}},ir[23:2],2'b00};
    wire [31:0] short_branch = debug_pc + {{19{ir[12]}},ir[12:2],2'b00};
    wire [2:0] cmp = c1==c2 ? 3'd2 :
        ((op[3] ? $signed(c1)<$signed(c2) : c1<c2) ? 3'd4 : 3'd1);
    wire [2:0] regcmp = s1==s2 ? 3'd2 :
        ((subop[0] ? $signed(s1)<$signed(s2) : s1<s2) ? 3'd4 : 3'd1);
    wire [31:0] bitmask = 32'd1 << s1[4:0];
    wire [31:0] idx = r[ir[4:0]] << ir[9:7];
    assign debug_reg_data = r[debug_reg_addr];
    assign debug_ac = ac;
    assign debug_process_control = pc;

    task bus_read(input [31:0] a, input [5:0] next_state);
        begin
            if (dbuf_valid && a[31:4]==dbuf_base) begin
                // served from the read buffer next cycle (DBUF_HIT), no bus transaction
                dbuf_sel <= a[3:2]; resume_state <= next_state; state <= DBUF_HIT;
                perf_dbuf_hit <= perf_dbuf_hit+1'b1;
            end else begin
                addr <= {a[31:2],2'b00}; be <= 4'hf; write <= 0;
                req <= 1; resume_state <= next_state; state <= WAIT_BUS;
                if (next_state==DECODE || next_state==EA_EXT_FILL) perf_ifetch <= perf_ifetch+1'b1;
                else perf_data_rd <= perf_data_rd+1'b1;
            end
        end
    endtask
    task bus_write(input [31:0] a, input [31:0] d,
                   input [3:0] lanes, input [5:0] next_state);
        begin
            addr <= {a[31:2],2'b00}; wdata <= d; be <= lanes;
            // Invalidating an unrelated index is conservative and avoids a
            // second tag read port; the following fetch refills if necessary.
            instruction_valid[a[9:2]]<=0;
            if(a[31:4]==fill_base) fill_pending<=0;   // never re-validate a block being written
            if(a[31:4]==dbuf_base) dbuf_valid<=0;
            perf_data_wr <= perf_data_wr+1'b1;
            if(next_state==CALL_NEXT) perf_frames <= perf_frames+1'b1;
            if(a==32'h40000008 && lanes[0]) instruction_valid<=0;
            write <= 1; req <= 1; resume_state <= next_state; state <= WAIT_BUS;
        end
    endtask
    task stop;
        begin halted <= 1; req <= 0; end
    endtask
    task start_call(input [31:0] target);
        begin
            call_irq <= 0; call_target <= target; frame_base <= r[31] & 32'hffffffc0;
            new_frame <= (r[1]+32'd63) & 32'hffffffc0;
            r[2] <= ip; count <= 0; state <= FC_ALLOC;
        end
    endtask
    integer i;
    reg [31:0] value;
    reg [32:0] carry_value;
    always @(posedge clk) begin
        register_write=0; register_index=0; register_value=0;
        retired <= 0; irq_pop <= 0;
        if (reset) begin
            instruction_valid<=0; state <= BOOT; req <= 0; write <= 0; be <= 0;
            fill_pending<=0; fill_base<=0; fill_data<=0; bus_value_wide<=0; bus_wide_ok<=0;
            cache_we<=0; cache_waddr<=0; cache_wdata<=0; cache_wtag<=0;
            dbuf<=0; dbuf_base<=0; dbuf_valid<=0; dbuf_sel<=0;
            fcount<=0; ftop<=0; fslot<=0; spill_then<=0;
            perf_wait<=0; perf_ifetch<=0; perf_data_rd<=0; perf_data_wr<=0; perf_frames<=0; perf_dbuf_hit<=0;
            addr <= 0; wdata <= 0; halted <= 0; ip <= 0; ir <= 0;
            sat <= 0; prcb <= 0; pc <= 32'h001f2002; ac <= 0; icr <= 32'hff000000;
            debug_pc <= 0; debug_opcode <= 0;
            call_irq<=0; check_irqs<=0; return_irq<=0; irq_vector<=0; irq_level<=0;
            irq_table<=0; pending_levels<=0; saved_process_control<=0;
            for(i=0;i<32;i=i+1) r[i] <= 0;
        end else if (!halted) begin
            // background block fill (one word per cycle; the decode states own the write port)
            cache_we<=0;
            if (fill_pending!=0 && state!=DECODE && state!=EA_EXT_FILL) begin
                cache_we<=1; cache_wtag<=fill_base[27:6];
                if (fill_pending[0]) begin cache_waddr<={fill_base[5:0],2'd0}; cache_wdata<=fill_data[31:0]; instruction_valid[{fill_base[5:0],2'd0}]<=1; fill_pending[0]<=0; end
                else if (fill_pending[1]) begin cache_waddr<={fill_base[5:0],2'd1}; cache_wdata<=fill_data[63:32]; instruction_valid[{fill_base[5:0],2'd1}]<=1; fill_pending[1]<=0; end
                else if (fill_pending[2]) begin cache_waddr<={fill_base[5:0],2'd2}; cache_wdata<=fill_data[95:64]; instruction_valid[{fill_base[5:0],2'd2}]<=1; fill_pending[2]<=0; end
                else begin cache_waddr<={fill_base[5:0],2'd3}; cache_wdata<=fill_data[127:96]; instruction_valid[{fill_base[5:0],2'd3}]<=1; fill_pending[3]<=0; end
            end
            case (state)
                DBUF_HIT: begin
                    bus_value <= dbuf[32*dbuf_sel+:32]; bus_value_wide <= dbuf; bus_wide_ok <= 1;
                    state <= resume_state;
                end
                WAIT_BUS: begin
                    perf_wait <= perf_wait+1'b1;
                    if (ready) begin
                        req <= 0; bus_value <= rdata; bus_value_wide <= rdata_wide; bus_wide_ok <= rdata_wide_valid; state <= resume_state;
                        if (!write && rdata_wide_valid) begin dbuf <= rdata_wide; dbuf_base <= addr[31:4]; dbuf_valid <= 1; end
                    end
                end
                BOOT: bus_read(0,SAT);
                SAT: begin sat <= bus_value; bus_read(4,PRCB); end
                PRCB: begin prcb <= bus_value; bus_read(12,IP); end
                IP: begin ip <= bus_value; bus_read(prcb+24,STACK); end
                STACK: begin r[31] <= bus_value; r[1] <= bus_value+64; state <= FETCH; end
                FETCH: if (!pause) begin
                    if(selected_valid && irq_pop==0) begin
                        irq_pop<=4'b1<<selected_line;
                        irq_vector<=selected_vector;
                        // Vector zero selects IAC mode, which this bring-up
                        // implementation does not implement (as in MAME).
                        if(selected_vector>=8) bus_read(prcb+20,IRQ_TABLE);
                    end else if(check_irqs) begin
                        check_irqs<=0; bus_read(prcb+20,IRQ_CHECK_TABLE);
                    end else begin
                        debug_pc <= ip; ip <= ip+4; state<=ICACHE_CHECK;
                    end
                end
                ICACHE_CHECK:begin
                    if(cached_valid && cached_tag==debug_pc[31:10]) begin
                        ir<=cached_instruction; debug_opcode<=cached_instruction; state<=6'd24;
                    end else bus_read(debug_pc,DECODE);
                end
                DECODE: begin
                    cache_we<=1; cache_waddr<=debug_pc[9:2]; cache_wdata<=bus_value; cache_wtag<=debug_pc[31:10];
                    instruction_valid[debug_pc[9:2]]<=1;
                    if (bus_wide_ok) begin fill_data<=bus_value_wide; fill_base<=debug_pc[31:4]; fill_pending<=4'b1111 & ~(4'b0001<<debug_pc[3:2]); end
                    ir <= bus_value; debug_opcode <= bus_value;
                    state <= 6'd24;
                end
                // Displacement word of a 2-word (MEMB) instruction fetched from the bus: cache it too.
                EA_EXT_FILL: begin
                    cache_we<=1; cache_waddr<=ext_addr[9:2]; cache_wdata<=bus_value; cache_wtag<=ext_addr[31:10];
                    instruction_valid[ext_addr[9:2]]<=1;
                    if (bus_wide_ok) begin fill_data<=bus_value_wide; fill_base<=ext_addr[31:4]; fill_pending<=4'b1111 & ~(4'b0001<<ext_addr[3:2]); end
                    state <= EA_EXT;
                end
                6'd24: begin
                    state <= FETCH; retired <= 1;
                    if (op[7]) begin
                        retired <= 0; state <= MEMORY;
                        mem_write <= op[1]; sign_extend <= op[6];
                        bytes <= ((op & 8'hb8)==8'h80) ? 1 :
                                 ((op & 8'hb8)==8'h88) ? 2 : 4;
                        total <= op==8'h98 || op==8'h9a ? 2 :
                                 op==8'ha0 || op==8'ha2 ? 3 :
                                 op==8'hb0 || op==8'hb2 ? 4 : 1;
                        transfer_reg <= op==8'h98 || op==8'h9a ? (dst & 5'h1e) :
                            op==8'ha0 || op==8'ha2 || op==8'hb0 || op==8'hb2 ? (dst & 5'h1c) : dst;
                        count <= 0;
                        if (!ir[12]) ea <= (ir[13] ? r[ir[18:14]] : 0) + {19'd0,ir[12:0]};
                        else case(ir[13:10])
                            4: ea <= r[ir[18:14]];
                            7: ea <= r[ir[18:14]]+idx;
                            // displacement word: from the instruction cache when present (cached_* track ip)
                            5,12,13,14,15: begin
                                if (cached_valid && cached_tag==ip[31:10]) begin bus_value <= cached_instruction; state <= EA_EXT; end
                                else bus_read(ip,EA_EXT_FILL);
                                ip <= ip+4;
                            end
                            default: stop();
                        endcase
                    end else if(op>=8'h10 && op<=8'h17) begin
                        if(op[2:0]==0 ? ac[2:0]==0 : |(ac[2:0]&op[2:0])) ip <= branch;
                    end else if(op>=8'h20 && op<=8'h27) begin
                        write_register(dst, {31'd0,(op[2:0]==0 ? ac[2:0]==0 : |(ac[2:0]&op[2:0]))});
                    end else if(op>=8'h30 && op<=8'h3e && op!=8'h38) begin
                        if(op==8'h30 || op==8'h37) begin
                            if(c2[c1[4:0]]==op[0]) begin ac[2:0]<=2; ip<=short_branch; end
                            else ac[2:0]<=0;
                        end else begin
                            ac[2:0] <= cmp;
                            if (|(cmp & op[2:0])) ip <= short_branch;
                        end
                    end else case(op)
                        8'h08: ip <= branch;
                        8'h09: begin start_call(branch); retired <= 0; end
                        8'h0a: begin
                            retired <= 0;
                            frame_base <= r[0]&32'hffffffc0; count<=0; return_irq<=r[0][2:0]==7;
                            case(r[0][2:0])
                                0:state<=FC_RET;
                                7:bus_read(r[31]-16,RET_PC);
                                default:stop();
                            endcase
                        end
                        8'h0b: begin r[30]<=ip; ip<=branch; end
                        8'h58: case(subop)
                            0:write_register(dst,s2^bitmask); 1:write_register(dst,s2&s1);
                            2:write_register(dst,s2&~s1); 3:write_register(dst,s2|bitmask);
                            4:write_register(dst,~s2&s1); 6:write_register(dst,s2^s1);
                            7:write_register(dst,s2|s1); 8:write_register(dst,~(s2|s1));
                            9:write_register(dst,~(s2^s1)); 10:write_register(dst,~s1);
                            11:write_register(dst,s2|~s1); 12:write_register(dst,s2&~bitmask);
                            13:write_register(dst,~s2|s1); 14:write_register(dst,~(s2&s1));
                            15:write_register(dst,ac[1] ? s2|bitmask : s2&~bitmask);
                            default:stop();
                        endcase
                        8'h59: case(subop)
                            0,1:write_register(dst,s2+s1);
                            2,3:write_register(dst,s2-s1);
                            8:write_register(dst,s1>=32 ? 0 : s2>>s1[4:0]);
                            10:begin
                                value = $signed(s2) >>> s1[4:0];
                                if(s2[31] && (s2 & ((32'd1<<s1[4:0])-1))!=0) value=value+1;
                                write_register(dst, s1>=32 ? 0 : value);
                            end
                            11:begin
                                // Keep the signed shift out of the unsigned ternary
                                // context; otherwise >>> silently becomes a logical shift.
                                value = $signed(s2) >>> s1[4:0];
                                write_register(dst,s1>=32 ? {32{s2[31]}} : value);
                            end
                            12,14:write_register(dst,s1>=32 ? 0 : s2<<s1[4:0]);
                            13:write_register(dst,(s2<<s1[4:0])|(s2>>(32-{27'd0,s1[4:0]})));
                            default:stop();
                        endcase
                        8'h5a: case(subop)
                            0,1:ac[2:0]<=regcmp;
                            // CONCMP preserves AC when L is already set; otherwise
                            // <= sets E and > sets G (including the signed variant).
                            2,3:if(!ac[2]) ac[2:0]<=regcmp==3'd1 ? 3'd1 : 3'd2;
                            4,5:begin ac[2:0]<=regcmp; write_register(dst,s2+1); end
                            6,7:begin ac[2:0]<=regcmp; write_register(dst,s2-1); end
                            12:ac[2:0] <= (s1[7:0]==s2[7:0] || s1[15:8]==s2[15:8] ||
                                s1[23:16]==s2[23:16] || s1[31:24]==s2[31:24]) ? 2 : 0;
                            14:ac[2:0]<=s2[s1[4:0]] ? 2 : 0;
                            default:stop();
                        endcase
                        8'h5b: if(subop==0 || subop==2) begin
                            carry_value = subop==0 ? {1'b0,s2}+{1'b0,s1}+{32'd0,ac[1]} :
                                                                   {1'b0,s2}-{1'b0,s1}-{32'd0,ac[1]};
                            write_register(dst,carry_value[31:0]); ac[1]<=carry_value[32];
                            ac[0]<=subop==0 ? ((carry_value[31]^s1[31])&(carry_value[31]^s2[31])) :
                                                             ((s2[31]^s1[31])&(s2[31]^carry_value[31]));
                        end else stop();
                        8'h5c,8'h5d,8'h5e,8'h5f: if(subop==12) begin
                            if(op==8'h5c) write_register(dst,s1);
                            else begin
                                for(i=0;i<4;i=i+1) move_values[i]<=ir[11] ? s1 : r[(int'(ir[4:0])+i)&31];
                                transfer_reg<=op==8'h5d ? (dst&5'h1e) : (dst&5'h1c);
                                count<=0; total<={3'd0,op[1:0]}+1'b1;
                                state<=MOVE_MULTI; retired<=0;
                            end
                        end else stop();
                        8'h60: if(subop==0 || subop==2) begin
                            syn_dst<=s1; syn_src<=s2; count<=0;
                            total<=subop==0 ? 1 : 4; state<=SYN_LOAD; retired<=0;
                        end else stop();
                        8'h64: case(subop)
                            0,1:begin
                                value=32'hffffffff;
                                for(i=0;i<32;i=i+1) if(s1[i]==subop[0]) value=i;
                                write_register(dst,value); ac[2:0]<=value==32'hffffffff ? 0 : 2;
                            end
                            5:begin write_register(dst,ac); ac<=(ac&~s1)|(s2&s1); end
                            default:stop();
                        endcase
                        8'h65: if(subop==5) begin
                            write_register(dst,pc); pc<=(pc&~s2)|(r[dst]&s2); check_irqs<=1;
                        end else stop();
                        // Inactive frames are always written to memory by CALL_SAVE.
                        8'h66: if(subop!=13) stop(); else if(fcount!=0) begin retired<=0; state<=FC_FLUSH; end
                        8'h67,8'h70,8'h74:begin
                            retired<=0;transfer_reg<=dst;arithmetic_count<=0;
                            arithmetic_pair<=op==8'h67;
                            if((op==8'h67 && subop==0) || (op!=8'h67 && subop==1)) begin
                                multiply_acc<=0;multiply_shift<={32'd0,s1};multiply_bits<=s2;state<=MULTIPLY;
                            end else if((op==8'h67 && subop==1) || (op!=8'h67 && (subop==8 || subop==11 || (op==8'h74 && subop==9)))) begin
                                divide_signed<=op==8'h74;
                                divide_negative_q<=op==8'h74 && (s1[31]^s2[31]);
                                divide_negative_r<=op==8'h74 && s2[31];
                                divide_result<=subop==8 ? 1 : subop==9 ? 2 : 0;
                                divide_by<=op==8'h74 && s1[31] ? -s1 : s1;
                                divide_q<=op==8'h74 && s2[31] ? -s2 : s2;
                                divide_r<=op==8'h67 && !ir[12] ? r[ir[18:14]+5'd1] : 32'd0;
                                state<=DIVIDE;
                                // Fault dispatch remains pending. Stop on division faults;
                                // never continue with a fabricated quotient.
                                if(s1==0 || (op==8'h74 && s2==32'h80000000 && s1==32'hffffffff && subop==11) ||
                                   (op==8'h67 && !ir[12] && r[ir[18:14]+5'd1]>=s1)) stop();
                            end else stop();
                        end
                        default:stop();
                    endcase
                end
                EA_EXT: begin
                    state <= MEMORY;
                    case(ir[13:10])
                        5:ea<=bus_value+ip;
                        12:ea<=bus_value;
                        13:ea<=bus_value+r[ir[18:14]];
                        14:ea<=bus_value+idx;
                        15:ea<=bus_value+r[ir[18:14]]+idx;
                        default:stop();
                    endcase
                end
                MEMORY: begin
                    case(op)
                        8'h8c:begin write_register(dst,ea); retired<=1; state<=FETCH; end
                        8'h84:begin ip<=ea; retired<=1; state<=FETCH; end
                        8'h85:begin write_register(dst,ip); ip<=ea; retired<=1; state<=FETCH; end
                        8'h86:start_call(ea);
                        8'h80,8'h82,8'h88,8'h8a,8'h90,8'h92,8'h98,8'h9a,
                        8'ha0,8'ha2,8'hb0,8'hb2,8'hc0,8'hc2,8'hc8,8'hca:begin
                            split_access <= {1'b0,ea[1:0]}+bytes>4;
                            if ({1'b0,ea[1:0]}+bytes>4) begin
                                if(mem_write) bus_write(ea,r[transfer_reg] << (8*ea[1:0]),
                                    (bytes==2 ? 4'h3 : 4'hf)<<ea[1:0],6'd25);
                                else bus_read(ea,6'd25);
                            end
                            else if(mem_write) bus_write(ea,r[transfer_reg] << (8*ea[1:0]),
                                (bytes==1 ? 4'h1 : bytes==2 ? 4'h3 : 4'hf)<<ea[1:0], MEM_DONE);
                            else bus_read(ea,MEM_DONE);
                        end
                        default:stop();
                    endcase
                end
                MEM_DONE: begin
                    value=split_access ? split_low|(bus_value<<(32-8*ea[1:0])) : bus_value>>(8*ea[1:0]);
                    if(!mem_write) write_register(transfer_reg, bytes==1 ? {{24{sign_extend&value[7]}},value[7:0]} :
                        bytes==2 ? {{16{sign_extend&value[15]}},value[15:0]} : value);
                    if(count+1==total) begin state<=FETCH; retired<=1; end
                    else begin count<=count+1; transfer_reg<=transfer_reg+1'b1; ea<=ea+4; state<=MEMORY; end
                end
                6'd25:begin
                    split_low<=bus_value>>(8*ea[1:0]);
                    if(mem_write) bus_write((ea&32'hfffffffc)+4,
                        r[transfer_reg]>>(32-8*ea[1:0]),
                        (bytes==2 ? 4'h3 : 4'hf)>>(4-ea[1:0]),MEM_DONE);
                    else bus_read((ea&32'hfffffffc)+4,MEM_DONE);
                end
                // ---- register frame cache
                FC_ALLOC: if(fcount==3'd4) begin fslot<=foldest; count<=0; spill_then<=FC_ALLOC; state<=FC_SPILL_RD; end
                          else state<=FC_ALLOC2;
                FC_ALLOC2: begin fslot<=ftop; fcache_tag[ftop]<=frame_base[31:6]; count<=0; ftop<=ftop+1'b1; fcount<=fcount+1'b1; state<=FC_SAVE; end
                FC_SAVE: begin fcache[{fslot,count[3:0]}]<=r[count]; if(count==15) state<=CALL_FINISH; else count<=count+1; end
                FC_SPILL_RD: state<=FC_SPILL_WR;                   // fcache_q <= the word
                FC_SPILL_WR: bus_write({fcache_tag[fslot],6'd0}+{25'd0,count,2'b00},fcache_q,4'hf,FC_SPILL_NEXT);
                FC_SPILL_NEXT: if(count==15) begin fcount<=fcount-1'b1; state<=spill_then; end
                               else begin count<=count+1; state<=FC_SPILL_RD; end
                FC_RET: if(fcount!=0 && fcache_tag[ftop-1'b1]==frame_base[31:6]) begin fslot<=ftop-1'b1; count<=0; state<=FC_LOAD_RD; end
                        else if(fcount!=0) begin fslot<=foldest; count<=0; spill_then<=FC_RET; state<=FC_SPILL_RD; end   // stack switch
                        else begin count<=0; state<=RET_LOAD; end   // count is 15 after a spill: restart the memory reload at r0
                FC_LOAD_RD: state<=FC_LOAD_WR;                     // fcache_q <= the word
                FC_LOAD_WR: begin
                    write_register(count,fcache_q);
                    if(count==15) begin ftop<=ftop-1'b1; fcount<=fcount-1'b1; state<=RET_FINISH; end
                    else begin count<=count+1; state<=FC_LOAD_RD; end
                end
                FC_FLUSH: if(fcount==0) begin state<=FETCH; retired<=1; end
                          else begin fslot<=foldest; count<=0; spill_then<=FC_FLUSH; state<=FC_SPILL_RD; end
                CALL_SAVE: bus_write(frame_base+{25'd0,count,2'b00},r[count],4'hf,CALL_NEXT);
                CALL_NEXT: if(count==15) state<=CALL_FINISH; else begin count<=count+1; state<=CALL_SAVE; end
                CALL_FINISH: begin
                    r[0]<=(r[31]&32'hfffffff8) | (call_irq ? 32'd7 : 32'd0);
                    r[31]<=new_frame; r[1]<=new_frame+64;
                    ip<=call_target; state<=call_irq ? IRQ_SAVE_PC : FETCH;
                    retired<=!call_irq;
                end
                RET_LOAD: bus_read(frame_base+{25'd0,count,2'b00},RET_NEXT);
                RET_NEXT: begin
                    write_register(count,bus_value);
                    if(count==15) state<=RET_FINISH; else begin count<=count+1; state<=RET_LOAD; end
                end
                RET_FINISH:begin
                    r[31]<=frame_base; ip<=r[2]; state<=FETCH; retired<=1; check_irqs<=return_irq;
                end
                MOVE_MULTI:begin
                    write_register(transfer_reg,move_values[count[1:0]]);
                    if(count+1==total) begin retired<=1; state<=FETCH; end
                    else begin count<=count+1'b1; transfer_reg<=transfer_reg+1'b1; end
                end
                MULTIPLY:begin
                    multiply_acc<=multiply_sum;multiply_shift<=multiply_shift<<1;multiply_bits<=multiply_bits>>1;
                    if(arithmetic_count==31) begin
                        if(arithmetic_pair) begin
                            move_values[0]<=multiply_sum[31:0];move_values[1]<=multiply_sum[63:32];
                            count<=0;total<=2;state<=MOVE_MULTI;
                        end else begin write_register(transfer_reg,multiply_sum[31:0]);retired<=1;state<=FETCH;end
                    end else arithmetic_count<=arithmetic_count+1'b1;
                end
                DIVIDE:begin
                    divide_r<=divide_next_r[31:0];divide_q<=divide_next_q;
                    if(arithmetic_count==31) state<=DIVIDE_FINISH;
                    else arithmetic_count<=arithmetic_count+1'b1;
                end
                DIVIDE_FINISH:begin
                    if(arithmetic_pair) begin
                        move_values[0]<=divide_r;move_values[1]<=divide_q;count<=0;total<=2;state<=MOVE_MULTI;
                    end else begin
                        value=divide_negative_r ? -divide_r : divide_r;
                        if(divide_result==2 && divide_negative_q && divide_r!=0) value=value+s1;
                        write_register(transfer_reg,divide_result==0 ? (divide_negative_q ? -divide_q : divide_q) : value);
                        retired<=1;state<=FETCH;
                    end
                end
                RET_PC:begin saved_process_control<=bus_value; bus_read(r[31]-12,RET_AC); end
                RET_AC:begin pc<=saved_process_control; ac<=bus_value; state<=FC_RET; end
                IRQ_TABLE:begin
                    irq_table<=bus_value;
                    if(irq_vector[7:3]>pc[20:16] || irq_vector[7:3]==31)
                        bus_read(prcb+24,IRQ_STACK);
                    else bus_read(bus_value,IRQ_PEND_LEVEL);
                end
                IRQ_PEND_LEVEL:bus_write(irq_table,bus_value|(32'd1<<irq_vector[7:3]),4'hf,IRQ_PEND_ADDR);
                IRQ_PEND_ADDR:bus_read(irq_table+4+{27'd0,irq_vector[7:5],2'b00},IRQ_PEND_WORD);
                IRQ_PEND_WORD:bus_write(irq_table+4+{27'd0,irq_vector[7:5],2'b00},
                    bus_value|(32'd1<<irq_vector[4:0]),4'hf,FETCH);
                IRQ_CHECK_TABLE:begin irq_table<=bus_value; bus_read(bus_value,IRQ_CHECK_LEVEL); end
                IRQ_CHECK_LEVEL:begin
                    value=32'hffffffff;
                    for(i=0;i<32;i=i+1)
                        if(bus_value[i] && (i>pc[20:16] || i==31)) value=i;
                    if(value==32'hffffffff) state<=FETCH;
                    else begin
                        pending_levels<=bus_value; irq_level<=value[4:0];
                        bus_read(irq_table+4+{27'd0,value[4:2],2'b00},IRQ_CHECK_WORD);
                    end
                end
                IRQ_CHECK_WORD:begin
                    value=32'hffffffff;
                    for(i=0;i<32;i=i+1)
                        if(bus_value[i] && i/8=={30'd0,irq_level[1:0]}) value=i;
                    if(value==32'hffffffff) begin
                        // Clear an empty priority group without inventing a vector.
                        bus_write(irq_table,pending_levels&~(32'd1<<irq_level),4'hf,FETCH);
                        check_irqs<=1;
                    end else begin
                        irq_vector<={irq_level[4:2],value[4:0]};
                        if((bus_value & (32'hff << (8*irq_level[1:0]))) == (32'd1<<value[4:0]))
                            pending_levels<=pending_levels&~(32'd1<<irq_level);
                        bus_write(irq_table+4+{27'd0,irq_level[4:2],2'b00},
                            bus_value&~(32'd1<<value[4:0]),4'hf,IRQ_CLEAR_LEVEL);
                    end
                end
                IRQ_CLEAR_LEVEL:bus_write(irq_table,pending_levels,4'hf,IRQ_DISPATCH);
                IRQ_DISPATCH:bus_read(prcb+24,IRQ_STACK);
                IRQ_STACK:begin
                    new_frame<=(( (pc[13] ? r[1] : bus_value)+63)&32'hffffffc0)+64;
                    bus_read(irq_table+4+{22'd0,irq_vector,2'b00},IRQ_VECTOR);
                end
                IRQ_VECTOR:begin
                    call_irq<=1; call_target<=bus_value; frame_base<=r[31]&32'hffffffc0;
                    r[2]<=ip; count<=0; state<=FC_ALLOC;   // interrupted frame goes into the frame cache like a call (its type-7 ret then hits)
                end
                IRQ_SAVE_PC:bus_write(r[31]-16,pc,4'hf,IRQ_SAVE_AC);
                IRQ_SAVE_AC:bus_write(r[31]-12,ac,4'hf,IRQ_SAVE_VECTOR);
                IRQ_SAVE_VECTOR:bus_write(r[31]-8,{24'd0,irq_vector}-8,4'hf,IRQ_ENTER);
                IRQ_ENTER:begin
                    // Priority is bits 20:16; clear it before installing the new
                    // level, including when its bit pattern differs from the old.
                    pc<=(pc&~32'h001f1f00)|{11'd0,irq_vector[7:3],16'd0}|32'h2002;
                    call_irq<=0; state<=FETCH;
                end
                SYN_LOAD:bus_read(syn_src+{25'd0,count,2'b00},SYN_NEXT);
                SYN_NEXT:begin
                    syn_data[count[1:0]]<=bus_value;
                    if(count+1==total) begin count<=0; state<=SYN_EXEC; end
                    else begin count<=count+1; state<=SYN_LOAD; end
                end
                SYN_EXEC:begin
                    ac[2:0]<=2;
                    if(syn_dst==32'hff000010) begin
                        state<=FETCH; retired<=1;
                        case(syn_data[0][31:24])
                            8'h93:begin sat<=syn_data[1]; prcb<=syn_data[2]; ip<=syn_data[3]; end
                            8'h89:instruction_valid<=0;
                            8'h8f,8'h92:begin end
                            8'h41:check_irqs<=1;
                            8'h80:begin state<=IAC_STORE; retired<=0; end
                            default:stop();
                        endcase
                    end else if(syn_dst==32'hff000004) begin
                        icr<=syn_data[0]; state<=FETCH; retired<=1;
                    end else state<=SYN_WRITE;
                end
                SYN_WRITE:bus_write(syn_dst+{25'd0,count,2'b00},syn_data[count[1:0]],4'hf,SYN_WNEXT);
                SYN_WNEXT:if(count+1==total) begin state<=FETCH; retired<=1; end
                    else begin count<=count+1; state<=SYN_WRITE; end
                IAC_STORE:bus_write(syn_data[1],sat,4'hf,IAC_STORE2);
                IAC_STORE2:bus_write(syn_data[1]+4,prcb,4'hf,FETCH);
                default:stop();
            endcase
        end
        if(register_write) r[register_index]<=register_value;
    end
endmodule
