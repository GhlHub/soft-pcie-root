// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_dllp_oracle;
    reg clk=0;always #2 clk=~clk;
    reg reset_i=1,start_stream=0,abort_i=0,valid=0;
    reg [31:0] data=0;reg [1:0] position=0;
    wire active,eds,tlp_valid,tlp_last,response,nak,dllp,error;
    wire [31:0] tlp_data,dllp_body;wire [1:0] packet_class;
    wire [8:0] credits;wire [11:0] sequence_number;
    gen3_data_rx dut(clk,reset_i,start_stream,abort_i,valid,data,position,
        active,eds,tlp_data,tlp_valid,tlp_last,1'b1,packet_class,credits,
        response,nak,sequence_number,dllp,dllp_body,error,);
    reg [292:0] cases[0:19999];reg [1023:0] path;
    integer count,c,w,received=0,errors=0,good_total=0,bad_total=0;
    reg [31:0] expected;
    always @(posedge clk)if(!reset_i)begin
        if(tlp_valid || response || nak)$fatal(1,"DLLP caused TLP event");
        if(error)errors=errors+1;
        if(dllp)begin
            if(dllp_body!==expected)$fatal(1,"DLLP byte order/body mismatch, case %0d",c);
            received=received+1;
        end
    end
    initial begin
        if(!$value$plusargs("cases=%s",path) || !$value$plusargs("count=%d",count))
            $fatal(1,"missing vectors");
        $readmemh(path,cases,0,count-1);
        repeat(2)@(negedge clk);reset_i=0;
        for(c=0;c<count;c=c+1)begin
            received=0;errors=0;expected=cases[c][287:256];
            start_stream=1;@(negedge clk);start_stream=0;
            for(w=0;w<int'(cases[c][291:288]);w=w+1)begin
                valid=1;position=2'(w);data=cases[c][32*w+:32];@(negedge clk);
                // Gaps stress parser state independently of byte alignment.
                if(w%3==1)begin valid=0;@(negedge clk);end
            end
            valid=0;repeat(8)@(negedge clk);
            if(cases[c][292])begin
                if(errors!=1 || received!=0)$fatal(1,"corruption escaped/duplicate errors, case %0d",c);
                bad_total=bad_total+1;
            end else begin
                if(errors!=0 || received!=1)$fatal(1,"good DLLP rejected, case %0d",c);
                good_total=good_total+1;
            end
        end
        $display("PASS: upstream DLLP oracle: %0d valid, %0d single-bit corruptions",good_total,bad_total);
        $finish;
    end
    initial begin #2000000;$fatal(1,"watchdog");end
endmodule
