// =============================================================
// mac_accelerator.v
// Parameterized Vector MAC (Multiply-Accumulate) Accelerator
// Y = SUM(A[i] * B[i]), i = 0 .. VECTOR_LEN-1
// Streaming-operand interface, single MAC unit, sequential FSM
// =============================================================

module mac_accelerator #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32,
    parameter VECTOR_LEN = 8
) (
    input                       clk,
    input                       rst_n,     // active-low async reset
    input                       start,     // pulse to begin a sequence
    input      [DATA_WIDTH-1:0] a_in,
    input      [DATA_WIDTH-1:0] b_in,
    output reg [ACC_WIDTH-1:0]  result,
    output                      busy,
    output reg                  done
);

    // ---------------------------------------------------------
    // FSM state encoding
    // ---------------------------------------------------------
    localparam S_IDLE    = 2'b00;
    localparam S_COMPUTE = 2'b01;
    localparam S_DONE    = 2'b10;

    reg [1:0] state, state_next;

    // ---------------------------------------------------------
    // Index counter width, derived from VECTOR_LEN (no magic numbers)
    // ---------------------------------------------------------
    localparam CNT_WIDTH = (VECTOR_LEN <= 1) ? 1 : $clog2(VECTOR_LEN);

    reg [CNT_WIDTH-1:0] count;
    reg [ACC_WIDTH-1:0] acc_reg;

    // ---------------------------------------------------------
    // Combinational datapath: multiplier
    // ---------------------------------------------------------
    wire [2*DATA_WIDTH-1:0] product;
    assign product = a_in * b_in;

    // ---------------------------------------------------------
    // Sequential: FSM state register
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= state_next;
    end

    // ---------------------------------------------------------
    // Combinational: next-state logic
    // ---------------------------------------------------------
    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE: begin
                if (start)
                    // VECTOR_LEN==1: the single MAC happens right here in this
                    // transition cycle, so go straight to DONE next cycle.
                    state_next = (VECTOR_LEN == 1) ? S_DONE : S_COMPUTE;
            end
            S_COMPUTE: begin
                // count == number of elements already accumulated *before*
                // this cycle. If VECTOR_LEN-1 of them are already done, this
                // cycle's accumulate is the final (Nth) one.
                if (count == VECTOR_LEN-1)
                    state_next = S_DONE;
            end
            S_DONE: begin
                state_next = S_IDLE;
            end
            default: state_next = S_IDLE;
        endcase
    end

    // ---------------------------------------------------------
    // Sequential: counter, accumulator, result, done
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count   <= {CNT_WIDTH{1'b0}};
            acc_reg <= {ACC_WIDTH{1'b0}};
            result  <= {ACC_WIDTH{1'b0}};
            done    <= 1'b0;
        end else begin
            done <= 1'b0; // default: single-cycle pulse

            case (state)
                S_IDLE: begin
                    if (start) begin
                        // a_in/b_in already hold element 0 this cycle -
                        // accumulate it now instead of wasting the cycle.
                        acc_reg <= product;
                        count   <= {CNT_WIDTH{1'b0}} + 1'b1;
                    end
                end

                S_COMPUTE: begin
                    acc_reg <= acc_reg + product;
                    if (count != VECTOR_LEN-1)
                        count <= count + 1'b1;
                end

                S_DONE: begin
                    result <= acc_reg;
                    done   <= 1'b1;
                end

                default: ; // no-op
            endcase
        end
    end

    // ---------------------------------------------------------
    // Output: busy
    // ---------------------------------------------------------
    assign busy = (state == S_COMPUTE);

endmodule
