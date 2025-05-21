`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company:         Christopher D. Nagy
// Engineer:        Christopher D. Nagy
// 
// File Name:		uart_baud_rate_generator.v
// Create Date:     05/19/2025 12:51:02 PM
// Design Name: 
// Module Name:     uart_baud_rate_generator
// Project Name:    Nagy_Example_Project 
// Target Devices:  Artix-7 [xc7a75tfgg484-1]
// Tool Versions:   Vivado 2024.2 
// Description: 
// 		Takes in a clock signal and divides it down to a desired 16x oversampled baud rate signal meant for use in serial UART based tx/rx driver modules.
//		Given a desired baud rate (passed in as a parameter, default: 115200 bps), this module will output a single clock pulse/tick at a rate 16 times the desired value. 
//		The outputted tick can be inputted to Tx and Rx driver modules to be courted and used to frame serial data transmissions and sampling data receptions.
//		Includes enable and asynchronous-clear input signal bits to allow resetting and disabling of this finite state machine module.
//		Default driving clock signal value is 150MHz. Can be changed by passing in the 
//
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 		This is a glorified synchronous clock divider.
//////////////////////////////////////////////////////////////////////////////////

/*	
	Example of Instantiation:

		wire 			clk150;
		wire 			reset_n;
		wire			uart_baud_rate_generator_enable;
		wire 			uart_tick_16x;
		wire			uart_baud_rate_generator_running;
		wire			uart_baud_rate_generator_done;
		wire	[7:0]	uart_baud_rate_generator_status;
		
		uart_baud_rate_generator	#(	.BAUDRATE(115200), 
										.CLK_FREQ(150_000_000))	UART_BAUD_RATE_GENERATOR(
																	.main_clk		(clk150),
																	.areset_n		(reset_n),
																	.enable			(uart_baud_rate_generator_enable),
																	.tick_16x		(uart_tick_16x),
																	.running		(uart_baud_rate_generator_running),
																	.done			(uart_baud_rate_generator_done),
																	.status			(uart_baud_rate_generator_status)
																);
*/
	
/******************************************************************************
*
*
*	Personal Note:
*
*		This Module is very much overkill in terms of the state machine detail and number of states needed
*		That being said, it's been written with purpose. 
*		It generalizes the 2-always output-coded state machine technique and includes many debugging helpers that I use in more complex systems
*		I find that generalizing how I write modules makes development time shorter and debugging easier
*		Some things can certainly be removed to tailor certain modules for size constraints...
*		but if you're running out of flip-flops, you probably have bigger issues.
*
*		I HIGH RECOMMEND checking out the published papers C. Cummings 
*		In particular: "Coding And Scripting Techniques For FSM Designs With Synthesis-Optimized, Glitch-Free Outputs" 
*			available at: http://www.sunburst-design.com/papers/CummingsSNUG2000Boston_FSM.pdf	
*		Mr. Cummings publications are absolute gold and my style is derived heavily from his writings. 		
*		I don't follow the described structure 100% faithfully, as I've added my own experience to my formatting and encoding style. 
*		However I certainly follow the technique of registered output for glitch-free output.
*			For example, larger bit wide outputs such as a counter's value that might be used as an input for another module are not explicitly mentioned in regards creating state registered outputs. 
*			It doesn't make sense to make hundreds of states for each output (with each possible output of the counter) and the flow of the state machine Combinational logic would be atrocious to write.  
*			So rather than that, I assign large outputs to registers of matching width that are in turn assigned only in the sequential logic always block and only rely on registered conditional logic (i.e state value and registered inputs)
*
*		Beside Mr. Cummings work and my own experience, the development of my state-machine module style includes influence from my Verilog and logic professors during my time in college: Pak K. Chan and Martine D. F. Schlag.
*
*****************************************************************************/

(* fsm_encoding = "user" *)
module uart_baud_rate_generator #(
	parameter BAUDRATE = 115200, 
	parameter CLK_FREQ = 150_000_000
) 	(

		input			main_clk,
		input			areset_n,
		
		input			enable,
		
		output			tick_16x,
		
		output	[7:0]	status
	);
	

	/* 
	*	Notes about local parameter BAUD_THRESHOLD_COUNT:
	*
	*	BAUD_THRESHOLD_COUNT is a calculation made at elaboration time (as a compile-time constant) using the passed or default parameter values
	*	The desired BAUDRATE is multiplied by 16 to accommodate for common 16x oversampling rate (16 ticks/slices per bit frame)
	*	The allowed BAUDRATE range is intended to be 245 bps to 115200 bps. This should be checked during simulation/verification testing.
	*		As such, BAUD_THRESHOLD_COUNT is truncated to 16 bits even though a CLK_FREQ of 150MHz (default value) would need 28 bits.
	*		150e6 / (245 * 16) = 16'd38265 [16'b1001_0101_0111_1001]
	*		245 bpd is chosen as a lower bound because it is the lowest effective baud rate achievable with standard Arduino serial communication. 
	*		I don't usually use Arduino's (I prefer ARMs and PICs over Atmel [no hate though]) but I thought it would be a common enough interface value for most cases.
	*		A bitrate of 50 bps is not really common, and this is just an example of my work, so I'm sticking to 245 bps as the lower limit. I'd adjust bit range values if I needed to.
	*		A BAUDRATE above 115200 is certainly possible and results in a lower than 16-bit count, but electrical considerations may come in to play and bit errors increased.
	*			For example 921600 bps [Maximum bitrate for a RP2040's ARM Cortex M0+] is possible to achieve and results in a count of 10 clock cycles (4-bits) when driven by a 150MHz clock signal
	*/

	localparam 	BAUD_THRESHOLD_COUNT 				= 	(CLK_FREQ / (BAUDRATE * 16)) & 16'hFFFF;	
	
	// The following list of local parameters describe the output possibilities for most or all of the module's outputs. 
	// They, along with 'status' values are used to create the encoding that describes the state machine's states. 
	localparam	TICK_H								=	1'b1,
				TICK_L								=	1'b0;
				
	localparam  RUNNING_H     						= 	1'b1,
				RUNNING_L      						= 	1'b0;
			
	localparam  DONE_H        						= 	1'b1,
				DONE_L         						= 	1'b0;	

	/* 
	*	Notes about the local parameter list making up state-machine state encoding [state names]:
	*
	* 	The values that make up each state name embed the module's output values for that state. 
	* 	All state names/encoding value are guaranteed to be unique given that each 8-bit 'status' value attached to the most significant bits of the state are unique.
	*	In most cases, the 'status' value does not need to be 8-bits, and they certainly don't need to be sequential. I make it that way for ease of development.
	*		A one-hot style encoding could save a few registers but would usually need to be tailored for each module written. Same with only adding minimum state encoding bits for states that have a non-unique output value.
	*		Using a generalized 8-bit sequential decimal count allows for quick encoding and easy look up of the state machines current state when using a logic analyzer [ila] or during simulation testing.
	*	The starting 'status' value [IDLE state] is 8'd1 rather than 8'd0
	*		This is because I've ran into issues when testing/debugging where the state machine falls into an unknown/unaccounted for state and the status shows up as 8'd0
	*		Starting at 8'd1 lets me know that I'm in the IDLE state at least and not in something completely unexpected or ambiguous.
	*		In other word, a 'status' value of 8'd0 will always mean there is something wrong with the module's logic or how it's written and needs development correction. 
	*	I always set the end 'status' value [DONE state] to 8'd255.
	*		Since the 8-bit register already exist, and 'DONE' is the last state, I just set it to 0xFFFF for easy identification when debugging.
	*		If for some reason more than 255 states are needed (256 is you include the implied error state of status == 8'd0), then I know where to start and end rebasing things.
	*		Also: I can't imagine a single module that needs 255 states. 
	*			I've made some very large state machines before during early prototype development stages (just to get my thoughts out of my mind and into Verilog)
	*			I always found timing closure and synthesis time to be much better after I redesign and divide the module into multiple modules [Divide and Conquer for the win]
	*			The cost is sometimes a clock cycle or two, but this overhead can be removed [if necessary] by acknowledging that the inputs of one module are guaranteed to be registered due to coming from a known registered output of the connected module.
	*/
	
	localparam  IDLE            					= 	{ 	8'd1,
															TICK_L,
															RUNNING_L,
															DONE_L},
													  
				COUNTING    						= 	{ 	8'd2,
															TICK_L,
															RUNNING_H,
															DONE_L},		
													  
				THRESHOLD_REACHED					=	{	8'd3,
															TICK_H,
															RUNNING_H,
															DONE_L},

				DONE            					= 	{ 	8'd255,
															TICK_L,
															RUNNING_H,
															DONE_H};


	// 	STATE_SIZE local parameter is declared here and used in elaboration time calculations to determine the state register's bit width
	//	The value is the total number of output bits, which is the same for all states. 
	// 	I use to not include this local parameter but found I was constantly making the error of either not updating the state or the output assignment's bit width when adding additional states during development.
	// 	The use of the local parameter means I only change one declared value when modifying the number of states. 
	//	It's actually a been a pretty good time saver due to mitigating human error when it comes time to generate the bitstream.
	localparam	STATE_SIZE 							= 	11;	

	//	State Register and State Register Output Assignments
	reg		[STATE_SIZE-1:0]	state, next;	 
	assign 	{	status,
				tick_16x,
				running,
				done} 								=	state[STATE_SIZE-1:0];
	
	// Other Registers [Input/Output/Internal]
	reg				ENABLE;		

	reg		[15:0]	BAUD_TICK_COUNTER;

	// always block #1 - Sequential Logic [sets/updates the registers at the time of a clock or reset edge given the current values of particular registers and inputs]
	always @(posedge main_clk or negedge areset_n)
	begin
		if (!areset_n) 
		begin
			state									<=	IDLE;
			
			ENABLE									<= 	1'b0;
			
			BAUD_TICK_COUNTER                      	<=  16'd0;
		end
		else
		begin
			state 									<=	next;
			
			ENABLE 									<= 	enable;

			if( (state != COUNTING) )
				BAUD_TICK_COUNTER                  	<=  16'd0;
            else if( (state == COUNTING) )
				BAUD_TICK_COUNTER					<=	BAUD_TICK_COUNTER + 16'd1;
            else
				BAUD_TICK_COUNTER					<=	BAUD_TICK_COUNTER;
		end
	end	

	// always block #2 - Combinational Logic [describes the conditions to go from one state to another]
	always @(*)
	begin
        case(state)
            IDLE									:	if( (ENABLE == 1'b1) )
															next = COUNTING;
														else																						
															next = IDLE;

			COUNTING								:	if( (BAUD_TICK_COUNTER == (BAUD_THRESHOLD_COUNT - 1)) )
															next = THRESHOLD_REACHED;
														else if( (BAUD_TICK_COUNTER > (BAUD_THRESHOLD_COUNT - 1)) )	// This should never happen and would normally be caught in simulation/verification
															next = DONE;  // Could be expanded to be a state that notifies of an error occurring
														else																						
															next = COUNTING;
														
														// 	Note that I don't check the ENABLE register here in order to continue to the next slice of the bit frame, but rather, I do so in the DONE state.
														// 		this is to match the number of clock cycles per iteration as the first iteration that leaves IDLE give the ENABLE bit.
														//		if I checked ENABLE here, all iterations would be the same cycle length except the first one, which would be one clock cycle longer
			THRESHOLD_REACHED						:	next = DONE;	 																													
		
			DONE									:	if( (ENABLE == 1'b1) )
															next = COUNTING;
														else																						
															next = IDLE;
				
            default             					:   next = state;
		endcase 
	end				
	
endmodule
	