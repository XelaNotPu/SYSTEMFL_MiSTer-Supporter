// SPDX-License-Identifier: GPL-3.0-or-later
// Two-tier priority word bus. Clients whose bit is set in HI are served ahead of
// the rest, so the deadline-critical video ROM fetches (C123 tile / C169 road /
// C355 sprite) and the C352 audio wave fetch are not starved by the CPU/MCU under
// a flat round-robin. Under full contention a flat 7-way round-robin gave the C123
// tile engine only 1/7 of the SDRAM, pushing its effective per-fetch latency past
// the scanline budget (~30-60 clk vs ~11 clk) and dropping upper-screen lines to
// black; C123 meets its deadline in isolation, so the shortfall is arbitration, not
// the engine. A bounded anti-starvation counter still forces a low-priority grant at
// least once every STARVE_LIMIT high grants, so the CPU and MCU can never be locked
// out (audio is itself high-priority and is never subject to it). Round-robin
// fairness is preserved within each tier. Hold each client's request through its
// ready pulse; drop it afterward before another transfer. Downstream payload is
// registered. With HI=0 this is identical to the original flat round-robin.
//
// Grant hold (client_lock): a client that fetches a multi-word row (C169: 4 pixel
// words + mask, C355: 4 words) asserts client_lock together with each request that
// will be followed immediately by a sequential one. When such a request completes,
// the next arbitration starts its scan AT that owner instead of after it, and waits
// up to a few cycles for the owner's next word, so the whole row costs one round of
// contention instead of one per word (the SDRAM read-ahead block cache then serves
// the follow-up words in a couple of cycles). The hold is bounded to LOCK_LIMIT
// consecutive words and is dropped by a forced anti-starvation grant, so no client
// can monopolise the bus. client_lock=0 restores the exact original behaviour.
//
// Deadline urgency (client_urgency): each high-tier client reports how many
// scanlines of slack it has before the raster needs the line it is composing
// (0 = due now .. 7 = relaxed; audio reports 0). Among the pending high-tier
// clients only those with the SMALLEST urgency value compete (round-robin among
// equals), and a grant hold is not waited for when a more urgent client is
// pending. On the busiest frames every engine over-runs its per-line budget at
// some rows; without this the round-robin spends bandwidth on an engine that is
// six lines ahead while the road engine drops its current line black. All zeros
// restores the plain two-tier round-robin.
module fl_client_arb #(parameter N=3, parameter [N-1:0] HI={N{1'b0}}, parameter STARVE_LIMIT=48,
                       parameter LOCK_LIMIT=8)(
    input wire clk,reset,
    input wire [N-1:0] client_req,client_write,client_lock,
    input wire [N-1:0][2:0] client_urgency,
    // While high, a pending low-priority (CPU/MCU) request wins over the high tier.
    // The board asserts it while the C116 display window is zeroed (screen blanked
    // during scene loads): video deadline misses are invisible then, and the i960's
    // bulk copies out of SDRAM would otherwise crawl at one grant per STARVE_LIMIT.
    input wire boost_lo,
    input wire [N-1:0][25:0] client_addr,
    input wire [N-1:0][31:0] client_data,
    input wire [N-1:0][3:0] client_be,
    output reg [N-1:0] client_ready,
    output reg req,write,output reg [25:0] addr,output reg [31:0] data,
    output reg [3:0] be,input wire ready
);
    localparam IW=(N>1) ? $clog2(N) : 1;   // client index width
    reg [1:0] state;
    reg [IW-1:0] owner,last_owner;
    // Registered scan origin: the client whose successor is scanned first. Equals
    // last_owner, or the client before it while the grant is held (locked), so the
    // held owner is re-scanned first. Tracked at the two places locked/last_owner
    // change instead of being derived combinationally: the 32-bit integer
    // subtract/compare that derivation implied sat in front of the whole grant
    // priority chain and missed the 50 MHz period by 23 ps at the cold corner.
    reg [IW-1:0] scan_base;
    integer grant,grant_hi,grant_lo;
    reg [IW:0] candidate;
    reg lo_pending;
    reg starve_force,locked;
    integer hi_streak,lock_count,lock_wait;
    reg [3:0] min_urgency;
    reg preempt;   // a pending high-tier client is more urgent than the held owner
    always @* begin
        grant_hi=-1; grant_lo=-1; lo_pending=1'b0; min_urgency=4'd8;
        for(integer n=0;n<N;n=n+1)
            if(client_req[n] && HI[n] && {1'b0,client_urgency[n]}<min_urgency) min_urgency={1'b0,client_urgency[n]};
        for(integer n=1;n<=N;n=n+1) begin
            candidate={1'b0,scan_base}+n[IW:0];
            if(candidate>=N) candidate=candidate-N;
            if(client_req[candidate]) begin
                if(HI[candidate]) begin if(grant_hi<0 && client_urgency[candidate]==min_urgency) grant_hi=candidate; end
                else begin if(grant_lo<0) grant_lo=candidate; lo_pending=1'b1; end
            end
        end
        preempt=grant_hi>=0 && min_urgency<{1'b0,client_urgency[last_owner]};
        // Relaxed high-tier work (every pending HI client at urgency 7: the frame-ahead road/sprite
        // framebuffers when ahead of their proportional schedule) yields to the CPU/MCU: since the
        // frame-ahead layers request all frame long, a strict two-tier bus starved the i960 to
        // ~64% game speed (Speed Racer's countdown, 2026-09-23). A layer that falls behind reports
        // urgency 2 and competes again, so the bandwidth balances itself; audio (0) and the
        // raster-bound tile engine (0..3 while active) are never yielded.
        if((starve_force || boost_lo) && grant_lo>=0) grant=grant_lo;
        else if(grant_hi>=0 && (min_urgency!=4'd7 || grant_lo<0)) grant=grant_hi;
        else grant=grant_lo;
    end
    always @(posedge clk) begin
        client_ready<=0;
        if(reset) begin
            state<=0; owner<=0; last_owner<=N-1; scan_base<=N-1;
            req<=0; write<=0; addr<=0; data<=0; be<=0;
            hi_streak<=0; starve_force<=0;
            locked<=0; lock_count<=0; lock_wait<=0;
        end else case(state)
            0:if(locked && !client_req[last_owner] && !preempt) begin
                // Give the held owner a few cycles to present its next word before
                // the bus is handed to anyone else.
                if(lock_wait>=3) begin locked<=0; lock_count<=0; lock_wait<=0; scan_base<=last_owner; end
                else lock_wait<=lock_wait+1;
            end else if(grant>=0) begin
                owner<=grant; req<=1; write<=client_write[grant];
                addr<=client_addr[grant]; data<=client_data[grant]; be<=client_be[grant]; state<=1;
                lock_wait<=0;
                if(HI[grant]) begin
                    if(lo_pending) begin
                        if(hi_streak+1>=STARVE_LIMIT) begin hi_streak<=0; starve_force<=1; end
                        else hi_streak<=hi_streak+1;
                    end
                end else begin
                    hi_streak<=0; starve_force<=0;
                end
            end
            1:if(ready) begin
                client_ready[owner]<=1; req<=0; last_owner<=owner; state<=2;
                if(client_lock[owner] && lock_count<LOCK_LIMIT-1) begin
                    locked<=1; lock_count<=lock_count+1;
                    scan_base<=(owner==0) ? N-1 : owner-1;   // re-scan the held owner first
                end else begin locked<=0; lock_count<=0; scan_base<=owner; end
            end
            2:if(!ready && !client_req[owner]) state<=0;
            default:state<=0;
        endcase
    end
endmodule
