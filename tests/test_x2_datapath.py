# SPDX-License-Identifier: Apache-2.0
"""Gen3 x2 packet/host datapath simulation; no PHY or hardware claims."""
from pathlib import Path
import subprocess
import pytest
from test_multilane import simulate, ROOT, RTL, GEN3
from test_gen3_packet_peer import tlp, dllp, ack

HOST = ROOT / 'ip/soft_pcie_root/rtl/host'


def body(words, marker=1, four=False):
    h = ((0x60000000 if four else 0x40000000) | words).to_bytes(4, 'big')
    return h + bytes.fromhex('01005aff') + (bytes(4) if four else b'') + (4096).to_bytes(4, 'big') + b''.join(
        ((marker << 16) | i).to_bytes(4, 'little') for i in range(words))


@pytest.mark.parametrize('offset', range(0,32,2))
@pytest.mark.parametrize('words', [1, 2, 3, 7, 31, 32])
def test_receive_x2(tmp_path, offset, words):
    packets = [body(words, n+1, bool(n%2)) for n in range(4)]
    corrupt = bytearray(tlp(1, packets[1])); corrupt[-1] ^= 0x80
    # Back-to-back token/body transitions, duplicate, bad CRC, retry and DLLP.
    stream = bytes(offset) + tlp(0, packets[0]) + tlp(0, packets[0]) + bytes(corrupt) + dllp(ack(7))
    stream += b''.join(tlp(n, packets[n]) for n in range(1,4)) + bytes(16)
    stream += bytes((-len(stream)) % 8)
    rows = [f"drive(64'h{int.from_bytes(stream[n:n+8], 'little'):016x},2'd{(n//8)%4});" for n in range(0,len(stream),8)]
    expected=[]
    for packet in packets:
        for n in range(0,len(packet),8):
            chunk=packet[n:n+8]
            expected.append((int.from_bytes(chunk,'little'),len(chunk)//4,int(n+8>=len(packet))))
    init='\n'.join(f"expected[{i}]=64'h{d:016x}; counts[{i}]={c}; lasts[{i}]={last};" for i,(d,c,last) in enumerate(expected))
    bench=f'''module tb;
reg clk=0;always #2 clk=~clk;
reg reset=1,start=0,abort_rx=0,valid=0,ready=0;
reg [63:0] data;reg [1:0] pos;
wire active,eds,v,last,response,nak,dllpv,error;
wire [63:0] out;wire [1:0] count,cl;wire [8:0] credits;wire [11:0] seq;wire [31:0] db;
reg [63:0] expected[0:{len(expected)-1}];integer counts[0:{len(expected)-1}],lasts[0:{len(expected)-1}];
integer received=0,responses=0,naks=0,errors=0,dllps=0,cycle=0;
reg held=0;reg [66:0] hold_data;
gen3_data_rx_x2 dut(clk,reset,start,abort_rx,valid,data,pos,active,eds,out,count,v,last,ready,cl,credits,response,nak,seq,dllpv,db,error,);
always @(posedge clk) if(!reset)begin
 cycle<=cycle+1;
 if(response)begin responses<=responses+1;if(nak)naks<=naks+1;end
 if(error)errors<=errors+1;
 if(dllpv)begin dllps<=dllps+1;if(db!==32'h07000000)$fatal(1,"DLLP body");end
 if(held && (!v||{{out,count,last}}!==hold_data))$fatal(1,"stalled RX changed");
 held<=v&&!ready;hold_data<={{out,count,last}};
 if(v&&ready)begin
  if(received>={len(expected)}||out!==expected[received]||count!==counts[received]||last!==lasts[received])$fatal(1,"RX word %0d data %h expected %h count %d",received,out,expected[received],count);
  if(cl!=0||credits!=({words}+3)/4)$fatal(1,"RX credit/class");
  received<=received+1;
 end
end
task drive(input [63:0] d,input [1:0] p);begin @(negedge clk);data=d;pos=p;valid=1;end endtask
initial begin
 {init}
 repeat(4)@(negedge clk);reset=0;start=1;@(negedge clk);start=0;
 {' '.join(rows)}
 @(negedge clk);valid=0;
 repeat(5)@(negedge clk);
 // Recovery abort must preserve all four committed packets and expected sequence.
 abort_rx=1;@(negedge clk);abort_rx=0;
 for(integer n=0;n<1000;n=n+1)begin @(negedge clk);ready=n%5!=0;end
 if(received!={len(expected)}||responses!=6||naks!=1||dllps!=1||errors!=1)$fatal(1,"RX totals %d %d %d %d %d",received,responses,naks,dllps,errors);
 $display("PASS x2 RX");$finish;
end
initial begin #20000;$fatal(1,"watchdog");end
endmodule'''
    simulate(tmp_path, bench, [GEN3/'gen3_data_rx_x2.sv'])


def run_bench(tmp_path, name, parameters=()):
    exe=tmp_path/'sim'
    files=[HOST/'pcie_ddr_bridge_x2.sv', ROOT/'tests/host'/f'{name}.sv']
    subprocess.run(['iverilog','-g2012','-s',name,*[f'-P{name}.{p}' for p in parameters],'-o',str(exe),*map(str,files)],check=True,capture_output=True,text=True)
    run=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=30)
    assert run.returncode==0,run.stdout+run.stderr
    assert 'PASS' in run.stdout


def test_ddr_x2_ownership(tmp_path):
    run_bench(tmp_path,'tb_ddr_bridge_x2')


@pytest.mark.parametrize('four',[0,1])
@pytest.mark.parametrize('align',range(4))
@pytest.mark.parametrize('words',[1,2,3,4,7,31,32])
@pytest.mark.parametrize('stalls',[0,1])
def test_ddr_x2_lanes(tmp_path,four,align,words,stalls):
    run_bench(tmp_path,'tb_ddr_pipeline_x2',[f'FOUR={four}',f'ALIGN={align}',f'WORDS={words}',f'STALLS={stalls}','MAX_SERVICE_CYCLES=100'])


@pytest.mark.parametrize('words',[1,2,3,7,16,31,32])
@pytest.mark.parametrize('stall',[0,1])
def test_tx_x2_replay(tmp_path,words,stall):
    packets=[body(words,n+1,bool(n%2)) for n in range(3)]
    frames=[tlp(n,p) for n,p in enumerate(packets)] + [tlp(n,packets[n]) for n in (1,2)]
    expected=[]
    for frame in frames:
        for n in range(0,len(frame),8):
            chunk=frame[n:n+8]
            expected.append((int.from_bytes(chunk,'little'),len(chunk)//4,int(n+8>=len(frame))))
    init='\n'.join(f"expected[{i}]=64'h{d:016x}; counts[{i}]={c}; lasts[{i}]={last};" for i,(d,c,last) in enumerate(expected))
    sends=[]
    for packet in packets:
        for n in range(0,len(packet),8):
            chunk=packet[n:n+8]
            sends.append(f"send(64'h{int.from_bytes(chunk,'little'):016x},2'd{len(chunk)//4},1'b{int(n+8>=len(packet))});")
    bench=f'''module tb;
reg clk=0;always #2 clk=~clk;
reg reset=1,enable=1,valid=0,last=0,ready=0,response=0,nak=0;
reg [63:0] data;reg [1:0] words;reg [11:0] seq=0;
wire in_ready,v,out_last,fault;wire [63:0] out;wire [1:0] out_words;
wire [3:0] pending,sent;wire [11:0] acknowledged,next_seq,events;
integer received=0,cycle=0;
reg [63:0] expected[0:{len(expected)-1}];integer counts[0:{len(expected)-1}],lasts[0:{len(expected)-1}];
reg held=0,packet_open=0;reg [66:0] hold_data;
gen3_tx_window_x2 #(.REPLAY_CYCLES(5000)) dut(clk,reset,enable,data,words,valid,last,in_ready,out,out_words,v,out_last,ready,response,nak,seq,pending,sent,acknowledged,next_seq,fault,events);
always @(negedge clk)ready=({stall}==0||cycle%5!=0);
always @(posedge clk)begin
 cycle<=cycle+1;
 if(!reset)begin
  if(fault)$fatal(1,"TX fault");
  if(packet_open&&!v)$fatal(1,"x2 formatter inserted an intra-packet bubble");
  if(v&&ready)packet_open<=!out_last;
  if(held&&(!v||{{out,out_words,out_last}}!==hold_data))$fatal(1,"TX stall changed");
  held<=v&&!ready;hold_data<={{out,out_words,out_last}};
  if(v&&ready)begin
   if(received>={len(expected)}||out!==expected[received]||out_words!=counts[received]||out_last!=lasts[received])$fatal(1,"TX beat %d got %h expected %h",received,out,expected[received]);
   received<=received+1;
  end
 end
end
task send(input [63:0] d,input [1:0] w,input l);begin
 @(negedge clk);data=d;words=w;last=l;valid=1;
 do @(posedge clk);while(!in_ready);
 @(negedge clk);valid=0;
end endtask
initial begin
 {init}
 repeat(4)@(negedge clk);reset=0;
 {' '.join(sends)}
 wait(sent==3);repeat(5)@(negedge clk);
 if(pending!=3)$fatal(1,"Submission retired ownership");
 response=1;nak=1;seq=0;@(negedge clk);response=0;
 wait(received=={len(expected)});repeat(10)@(negedge clk);
 if(pending!=2||acknowledged!=0)$fatal(1,"NAK ownership");
 response=1;nak=0;seq=2;@(negedge clk);response=0;
 repeat(12)@(negedge clk);
 if(pending!=0||acknowledged!=2)$fatal(1,"ACK retirement");
 $display("PASS x2 replay");$finish;
end
initial begin #100000;$fatal(1,"watchdog received %d pending %d sent %d",received,pending,sent);end
endmodule'''
    simulate(tmp_path,bench,[GEN3/'gen3_tx_window_x2.sv',GEN3/'gen3_tlp_source_x2.sv',GEN3/'gen3_stp.sv',RTL/'pcie_soft_replay.sv',RTL/'pcie_soft_ack_capture.sv'])


@pytest.mark.parametrize('input_words,output_words', [(2,4), (4,2), (2,1)])
def test_x2_width_adapter(tmp_path,input_words,output_words):
    # Every final occupancy, long streams, backpressure; explicit packet metadata.
    lengths=list(range(1,38))*3
    sends=[];expected=[]
    for p,length in enumerate(lengths):
        data=[(p<<16)|i for i in range(length)]
        for i in range(0,length,input_words):
            chunk=data[i:i+input_words]
            value=sum(d<<(32*k) for k,d in enumerate(chunk))
            sends.append(f"send({32*input_words}'h{value:x},3'd{len(chunk)},11'd{p},1'b{int(i+input_words>=length)});")
        for i in range(0,length,output_words):
            chunk=data[i:i+output_words]
            value=sum(d<<(32*k) for k,d in enumerate(chunk))
            expected.append((value,len(chunk),p,int(i+output_words>=length)))
    init='\n'.join(f"ex[{i}]={32*output_words}'h{d:x}; nw[{i}]={n}; meta[{i}]={p}; last_ex[{i}]={l};" for i,(d,n,p,l) in enumerate(expected))
    bench=f'''module tb;
reg clk=0;always #2 clk=~clk;reg rst=0,valid=0,last=0,ready=0;
reg [{32*input_words-1}:0] data;reg [2:0] words;reg [10:0] md;
wire in_ready,v,l,fault;wire [{32*output_words-1}:0] out;wire [2:0] ow;wire [10:0] om;
reg [{32*output_words-1}:0] ex[0:{len(expected)-1}];integer nw[0:{len(expected)-1}],meta[0:{len(expected)-1}],last_ex[0:{len(expected)-1}];
integer index=0,cycle=0;
pcie_packet_width #(.INPUT_DWORDS({input_words}),.OUTPUT_DWORDS({output_words})) dut(clk,rst,data,words,md,valid,last,in_ready,out,ow,om,v,l,ready,fault);
always @(negedge clk)ready=cycle%7<4;
always @(posedge clk)begin
 cycle<=cycle+1;
 if(rst&&fault)$fatal(1,"adapter fault");
 if(v&&ready)begin
  for(integer k=0;k<{output_words};k=k+1)if(k<ow&&out[32*k+:32]!==ex[index][32*k+:32])$fatal(1,"adapter data %d",index);
  if(ow!=nw[index]||om!=meta[index]||l!=last_ex[index])$fatal(1,"adapter metadata %d",index);
  index<=index+1;
 end
end
task send(input [{32*input_words-1}:0] d,input [2:0] w,input [10:0] m,input ll);begin
 @(negedge clk);data=d;words=w;md=m;last=ll;valid=1;do @(posedge clk);while(!in_ready);
end endtask
initial begin {init}
 repeat(4)@(negedge clk);rst=1;
 {' '.join(sends)}
 @(negedge clk);valid=0;
 wait(index=={len(expected)});$display("PASS width");$finish;
end
initial begin #200000;$fatal(1,"watchdog");end
endmodule'''
    simulate(tmp_path,bench,[HOST/'pcie_packet_width.sv'])


@pytest.mark.parametrize('offset',range(4))
@pytest.mark.parametrize('link_half,host_half',[(2,4),(3,5)])
def test_x2_host_cdc(tmp_path,offset,link_half,host_half):
    address=4096+4*offset
    payload=b''.join((0xabc00000+i).to_bytes(4,'little') for i in range(32))
    write=(0x40000020).to_bytes(4,'big')+bytes.fromhex('01005aff')+address.to_bytes(4,'big')+payload
    msi=bytes.fromhex('4000000101005a0ffee00000')+(17).to_bytes(4,'little')
    read=bytes.fromhex('0000002001005aff')+address.to_bytes(4,'big')
    sends=[]
    for packet in [write,msi,read]:
        for i in range(0,len(packet),8):
            chunk=packet[i:i+8]
            sends.append(f"send(64'h{int.from_bytes(chunk,'little'):016x},2'd{len(chunk)//4},1'b{int(i+8>=len(packet))});")
    expected=[];left=32;pos=address
    while left:
        chunk=min(left,16-(pos//4)%16)
        packet=(0x4a000000|chunk).to_bytes(4,'big')+(left*4).to_bytes(4,'big')+(0x01005a00|(pos%128)).to_bytes(4,'big')+payload[pos-address:pos-address+4*chunk]
        for i in range(0,len(packet),8):
            b=packet[i:i+8]
            expected.append((int.from_bytes(b,'little'),len(b)//4,int(i+8>=len(packet)),(chunk+3)//4))
        pos+=chunk*4;left-=chunk
    init='\n'.join(f"ex[{i}]=64'h{d:016x}; nw[{i}]={n}; le[{i}]={l}; ce[{i}]={c};" for i,(d,n,l,c) in enumerate(expected))
    bench=f'''module tb;
reg clk=0,link_clk=0,run_link=1,run_host=1;
always #{host_half} if(run_host)clk=~clk;
always #{link_half} if(run_link)link_clk=~link_clk;
reg rst_n=0;reg [63:0] rxdata;reg [1:0] rxwords;reg rxvalid=0,rxlast=0;
wire rxready;wire [63:0] txdata;wire [1:0] txwords;wire txvalid,txlast;reg txready=0;
wire [8:0] credits;wire [31:0] awaddr,araddr;wire [7:0] awlen,arlen;wire [2:0] awsize,arsize;
wire awvalid,wvalid,wlast,bready,arvalid,rready;wire [127:0] wdata;wire [15:0] wstrb;
reg awready=0,wready=0,bvalid=0,arready=0,rvalid=0,rlast=0;reg [127:0] rdata;
wire fault,idle,msi,rf,tf;wire [4:0] vector;
reg [7:0] mem[0:8191];integer wa=0,wi=0,ra=0,ri=0,rl=0,cycle=0,bdelay=0,irqs=0,index=0;
reg writing=0,reading=0;reg [63:0] ex[0:{len(expected)-1}];integer nw[0:{len(expected)-1}],le[0:{len(expected)-1}],ce[0:{len(expected)-1}];
pcie_x2_host_path dut(
 .clk(clk),.link_clk(link_clk),.rst_n(rst_n),.link_active_i(1'b1),.dma_enable_i(1'b1),
 .link_rx_data_i(rxdata),.link_rx_words_i(rxwords),.link_rx_valid_i(rxvalid),.link_rx_last_i(rxlast),.link_rx_ready_o(rxready),
 .link_tx_data_o(txdata),.link_tx_words_o(txwords),.link_tx_valid_o(txvalid),.link_tx_last_o(txlast),.link_tx_ready_i(txready),.link_tx_credits_o(credits),
 .rx_cross_fault_o(rf),.tx_cross_fault_o(tf),.fault_o(fault),.idle_o(idle),.msi_valid_o(msi),.msi_vector_o(vector),
 .m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
 .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wlast(wlast),.m_axi_wready(wready),
 .m_axi_bresp(2'b0),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
 .m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arsize(arsize),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
 .m_axi_rdata(rdata),.m_axi_rresp(2'b0),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
always @(negedge clk)begin cycle=cycle+1;awready=!writing&&cycle%3!=0;wready=writing&&cycle%5!=0;arready=!reading;end
always @(posedge clk)if(rst_n)begin
 if(fault||rf||tf)$fatal(1,"host path fault");
 if(awvalid&&awready)begin
  if(awsize!=4||awaddr!=4096||awlen!=({offset}+32+3)/4-1)$fatal(1,"AW geometry");
  wa<=awaddr;wi<=0;writing<=1;
 end
 if(wvalid&&wready)begin
  for(integer b=0;b<16;b=b+1)if(wstrb[b])mem[wa+16*wi+b]<=wdata[8*b+:8];
  wi<=wi+1;if(wlast)begin writing<=0;bdelay<=12;end
 end
 if(bdelay>0)begin bdelay<=bdelay-1;if(bdelay==1)bvalid<=1;end
 if(bvalid&&bready)bvalid<=0;
 if(msi)begin if(vector!=17||writing||bvalid||bdelay!=0)$fatal(1,"MSI B fence");irqs<=irqs+1;end
 if(arvalid&&arready)begin
  if(arsize!=4||arlen>3||araddr[3:0]!=0)$fatal(1,"AR geometry");
  ra<=araddr;ri<=0;rl<=arlen;reading<=1;
 end
 if(reading&&(!rvalid||rready)&&cycle%3!=0)begin
  for(integer b=0;b<16;b=b+1)rdata[8*b+:8]<=mem[ra+16*ri+b];
  rlast<=ri==rl;rvalid<=1;ri<=ri+1;if(ri==rl)reading<=0;
 end else if(rvalid&&rready)rvalid<=0;
end
always @(posedge link_clk)if(txvalid&&txready)begin
 for(integer k=0;k<2;k=k+1)if(k<txwords&&txdata[32*k+:32]!==ex[index][32*k+:32])$fatal(1,"CDC payload %d got %h expected %h",index,txdata,ex[index]);
 if(txwords!=nw[index]||txlast!=le[index]||credits!=ce[index])$fatal(1,"CDC metadata %d",index);
 index<=index+1;
end
task send(input [63:0] d,input [1:0] w,input l);begin
 @(negedge link_clk);rxdata=d;rxwords=w;rxlast=l;rxvalid=1;
 do @(posedge link_clk);while(!rxready);
 @(negedge link_clk);rxvalid=0;
end endtask
initial begin
 {init}
 for(integer b=0;b<8192;b=b+1)mem[b]=8'hcc;
 repeat(5)@(negedge clk);rst_n=1;
 // Pause the host clock while the first full packet crosses the FIFO.
 @(negedge clk);run_host=0;
 fork begin #600;run_host=1;end begin {' '.join(sends)} end join
 wait(txvalid);@(negedge link_clk);run_link=0;
 #300;run_link=1;
 for(integer n=0;n<1000;n=n+1)begin @(negedge link_clk);txready=n%7<5;end
 if(index!={len(expected)}||irqs!=1)$fatal(1,"CDC counts %d %d",index,irqs);
 for(integer b=4096;b<4096+144;b=b+1)if((b<{address}||b>={address+128})&&mem[b]!==8'hcc)$fatal(1,"CDC write guard");
 $display("PASS x2 CDC host");$finish;
end
initial begin #100000;$fatal(1,"watchdog");end
endmodule'''
    simulate(tmp_path,bench,[HOST/'pcie_x2_host_path.sv',HOST/'pcie_ddr_bridge_x2.sv',HOST/'pcie_packet_width.sv',HOST/'pcie_cdc_packet.sv'])


def link_files():
    return [GEN3/(n+'.sv') for n in ('gen3_link_layer_x2','gen3_link_profile','gen3_dllp_source_x2','gen3_tx_window_x2','gen3_tlp_source_x2','gen3_stp')]+[HOST/'pcie_packet_width.sv']+[RTL/(n+'.sv') for n in ('pcie_soft_flow_control','pcie_soft_requester','pcie_soft_replay','pcie_soft_ack_capture')]


def test_x2_link_requester_credits(tmp_path):
    import zlib
    from test_pcie_soft import crc16_packet
    exe=tmp_path/'sim';trace=tmp_path/'trace'
    subprocess.run(['iverilog','-g2012','-s','test_link_layer_x2','-o',str(exe),*map(str,link_files()),str(GEN3/'test_link_layer_x2.sv')],check=True,capture_output=True,text=True)
    result=subprocess.run(['vvp',str(exe),f'+OUT={trace}'],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stdout+result.stderr
    frames={}
    for line in trace.read_text().splitlines():
        frame,index,data,last=line.split()
        assert int(index)==len(frames.setdefault(int(frame),[]))
        frames[int(frame)].append(int(data,16))
    types=[];packets=[]
    for words in frames.values():
        data=b''.join(w.to_bytes(4,'little') for w in words)
        if data[:2]==b'\xf0\xac':
            assert len(data)==8 and int.from_bytes(data[6:],'little')==crc16_packet(data[2:6])
            types.append(data[2])
        else:
            token=words[0];sequence=((token>>16)&15)*256+(token>>24)
            assert words[-1]==zlib.crc32(sequence.to_bytes(2,'big')+data[4:-4])
            packets.append(words)
    assert len(packets)==2 and len(packets[0])==5 and len(packets[1])==37
    assert packets[0][1:4]==[0x01000004,0x0f000000,0x00000001]
    assert packets[1][1:-1]==[0x2000004a]+[0x12340000+j for j in range(1,35)]
    assert all(t in types for t in (0x40,0x50,0x60,0xc0,0xd0,0xe0,0))


def test_x2_replay_wrap_pause_exhaustion(tmp_path):
    import zlib
    exe=tmp_path/'sim';trace=tmp_path/'trace'
    files=[GEN3/(n+'.sv') for n in ('gen3_tx_window_x2','gen3_tlp_source_x2','gen3_stp','test_tx_window_x2')]+[RTL/'pcie_soft_replay.sv',RTL/'pcie_soft_ack_capture.sv']
    subprocess.run(['iverilog','-g2012','-s','test_tx_window_x2','-o',str(exe),*map(str,files)],check=True,capture_output=True,text=True)
    r=subprocess.run(['vvp',str(exe),f'+OUT={trace}'],capture_output=True,text=True,timeout=30)
    assert r.returncode==0,r.stdout+r.stderr
    frames={}
    for line in trace.read_text().splitlines():
        frame,index,data=line.split();assert int(index)==len(frames.setdefault(int(frame),[]))
        frames[int(frame)].append(int(data,16))
    assert len(frames)>4096
    for words in frames.values():
        assert len(words)==6
        token=words[0];seq=((token>>16)&15)*256+(token>>24)
        payload=b''.join(w.to_bytes(4,'little') for w in words[1:-1])
        assert words[-1]==zlib.crc32(seq.to_bytes(2,'big')+payload)


def rx_trace(tmp_path,program,words=64,slots=16):
    bench='''module tb;
reg clk=0;always #2 clk=~clk;
reg reset=1,start=0,abort_rx=0,valid=0,ready=1;reg [63:0] data;reg [1:0] pos;
wire active,eds,v,last,response,nak,dv,error;wire [63:0] out;wire [1:0] nw,cl;wire [8:0] cost;wire [11:0] seq;wire [31:0] db;
gen3_data_rx_x2 dut(clk,reset,start,abort_rx,valid,data,pos,active,eds,out,nw,v,last,ready,cl,cost,response,nak,seq,dv,db,error,);
always @(posedge clk)if(!reset)begin
 if(v&&ready)$display("D %016h %d %d",out,nw,last);
 if(response)$display("R %d %d",seq,nak);
 if(error)$display("E");if(eds)$display("EDS");if(dv)$display("L %08h",db);
end
task drive(input [63:0] d,input [1:0] p);begin @(negedge clk);data=d;pos=p;valid=1;end endtask
task wait_cycles(input integer n);begin @(negedge clk);valid=0;repeat(n)@(negedge clk);end endtask
task restart;begin @(negedge clk);valid=0;start=1;@(negedge clk);start=0;end endtask
initial begin repeat(4)@(negedge clk);reset=0;restart();
PROGRAM
wait_cycles(1500);$display("PASS");$finish;end
initial begin #2000000;$fatal(1,"watchdog");end
endmodule'''.replace('PROGRAM',program).replace('gen3_data_rx_x2 dut',
        f'gen3_data_rx_x2 #(.WORDS({words}),.SLOTS({slots})) dut')
    path=tmp_path/'trace_tb.sv';path.write_text(bench);exe=tmp_path/'sim'
    subprocess.run(['iverilog','-g2012','-s','tb','-o',str(exe),str(path),str(GEN3/'gen3_data_rx_x2.sv')],check=True,capture_output=True,text=True)
    result=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stdout+result.stderr
    packets=[];packet=bytearray();responses=[];errors=0;eds=0;dllps=[]
    for line in result.stdout.splitlines():
        fields=line.split()
        if fields[0]=='D':
            packet+=int(fields[1],16).to_bytes(8,'little')[:4*int(fields[2])]
            if int(fields[3]):packets.append(bytes(packet));packet.clear()
        elif fields[0]=='R':responses.append(tuple(map(int,fields[1:])))
        elif fields[0]=='E':errors+=1
        elif fields[0]=='EDS':eds+=1
        elif fields[0]=='L':dllps.append(int(fields[1],16))
    assert not packet
    return packets,responses,errors,eds,dllps


def drive_stream(stream):
    stream+=bytes((-len(stream))%8)
    return '\n'.join(f"drive(64'h{int.from_bytes(stream[i:i+8],'little'):016x},2'd{(i//8)%4});" for i in range(0,len(stream),8))


def test_x2_rx_sustained_wrap(tmp_path):
    packets=[body([1,2,7,32][i%4],i+1,bool(i%2)) for i in range(4098)]
    program=drive_stream(b''.join(tlp(i%4096,p) for i,p in enumerate(packets))+bytes(16))
    got,responses,errors,eds,dllps=rx_trace(tmp_path,program)
    assert got==packets and responses==[(i%4096,0) for i in range(4098)]
    assert errors==eds==0 and not dllps


def test_x2_rx_full_abort_nullify(tmp_path):
    packets=[body(1,i+1) for i in range(17)]
    stream=b''.join(tlp(i,p) for i,p in enumerate(packets))+bytes(16)
    nullified=bytearray(tlp(16,packets[16]))
    for i in range(1,5):nullified[-i]^=255
    nullified+=b'\xc0'*4
    # Preserve sixteen committed packets while aborting a later incomplete body.
    program='ready=0;'+drive_stream(stream)+drive_stream(tlp(16,packets[16])[:8])
    program+='wait_cycles(2);abort_rx=1;@(negedge clk);abort_rx=0;ready=1;wait_cycles(200);restart();'
    program+=drive_stream(bytes(nullified)+tlp(16,packets[16])+bytes(16))
    got,responses,errors,eds,dllps=rx_trace(tmp_path,program)
    assert got==packets
    assert responses==[(i,0) for i in range(16)]+[(15,1),(16,0)]
    assert errors==1 and eds==0 and not dllps


@pytest.mark.parametrize('fault',['token','dllp','eds','nullifier'])
def test_x2_rx_framing_faults(tmp_path,fault):
    p=body(1)
    if fault=='token':
        frame=bytearray(tlp(0,p));frame[2]^=16
    elif fault=='dllp':
        frame=bytearray(dllp(ack(4)));frame[-1]^=1
    elif fault=='eds':
        frame=bytearray(bytes.fromhex('1f809000')) # Wrong aggregate block position.
    else:
        frame=bytearray(tlp(0,p)+b'\xc0\xc0\xc0\x00')
    program=drive_stream(bytes(frame)+bytes(16))+'wait_cycles(3);restart();'+drive_stream(tlp(0,p)+bytes(16))
    # Valid EDS exactly at the aggregate block tail.
    program+=drive_stream(bytes(28)+bytes.fromhex('1f809000'))
    got,responses,errors,eds,_=rx_trace(tmp_path,program)
    assert got==[p] and responses==[(0,0)] and errors==1 and eds==1


@pytest.mark.parametrize('offset',range(1,32,2))
def test_x2_rx_idle_lane_alignment(tmp_path,offset):
    p=body(1)
    got,responses,errors,eds,_=rx_trace(tmp_path,drive_stream(bytes(offset)+tlp(0,p)+bytes(16)))
    assert not got and not responses and errors==1 and eds==0


@pytest.mark.parametrize('offset', [0, 2, 4, 6])
@pytest.mark.parametrize('words', [1, 2, 31, 32])
def test_x2_rx_sustained_nullified(tmp_path, offset, words):
    packet = body(words)
    null = bytearray(tlp(0, packet))
    for i in range(1, 5):
        null[-i] ^= 255
    null += b'\xc0' * 4
    # Continuous eight-byte input, including lengths that leave a four-byte
    # final body beat. No sequence/queue ownership for nullified candidates.
    stream = bytes(offset) + bytes(null) * 128 + tlp(0, packet) + bytes(16)
    got, responses, errors, eds, dllps = rx_trace(tmp_path, drive_stream(stream))
    assert got == [packet] and responses == [(0, 0)]
    assert errors == eds == 0 and not dllps


@pytest.mark.parametrize('offset', [0, 2, 4, 6])
def test_x2_rx_sustained_minimum_packets(tmp_path, offset):
    packet = bytes.fromhex('0000000101005aff00001000')
    packets = [packet] * 256
    stream = bytes(offset) + b''.join(tlp(i, p) for i, p in enumerate(packets)) + bytes(16)
    got, responses, errors, eds, dllps = rx_trace(tmp_path, drive_stream(stream))
    assert got == packets and responses == [(i, 0) for i in range(256)]
    assert errors == eds == 0 and not dllps


def test_x2_rx_eds_without_following_input(tmp_path):
    # No padding after the block-tail EDS. The ingress parser must drain its
    # final four buffered bytes even when valid_i stays low indefinitely.
    got, responses, errors, eds, dllps = rx_trace(
        tmp_path, drive_stream(bytes(28) + bytes.fromhex('1f809000')))
    assert not got and not responses and not dllps and errors == 0 and eds == 1


@pytest.mark.parametrize('cut', [8, 16, 24, 64, 128, 144])
@pytest.mark.parametrize('delay', [0, 1, 2, 3])
def test_x2_rx_abort_pipeline_preserves_committed(tmp_path, cut, delay):
    first, second = body(1, 19), body(31, 23)
    program = 'ready=0;' + drive_stream(tlp(0, first) + bytes(16))
    program += 'wait_cycles(12);' + drive_stream(tlp(1, second)[:cut])
    program += f'wait_cycles({delay});abort_rx=1;@(negedge clk);abort_rx=0;wait_cycles(4);restart();'
    program += drive_stream(tlp(1, second) + bytes(16))
    program += 'wait_cycles(12);ready=1;'
    got, responses, errors, eds, dllps = rx_trace(tmp_path, program)
    assert got == [first, second] and responses == [(0, 0), (1, 0)]
    assert errors == eds == 0 and not dllps


@pytest.mark.parametrize('offset', [0, 2, 4, 6])
def test_x2_rx_bubbles_and_dllp_burst(tmp_path, offset):
    packets = [body([1, 2, 3, 32][i % 4], i + 1) for i in range(80)]
    stream = bytes(offset)
    for i, packet in enumerate(packets):
        stream += dllp(ack(i)) * 3 + tlp(i, packet)
    stream += bytes(16)
    rows = drive_stream(stream).splitlines()
    program = '\n'.join(row + (f'wait_cycles({i % 3});' if i % 7 == 0 else '')
                        for i, row in enumerate(rows))
    got, responses, errors, eds, dllps = rx_trace(tmp_path, program)
    assert got == packets and responses == [(i, 0) for i in range(80)]
    assert errors == eds == 0 and len(dllps) == 240


def test_x2_rx_committed_packet_has_no_read_bubbles(tmp_path):
    packet = body(32)
    rows = drive_stream(tlp(0, packet) + bytes(16))
    bench = '''module tb;
reg clk=0;always #2 clk=~clk;
reg reset=1,start=0,valid=0,ready=0;reg [63:0] data;reg [1:0] pos;
wire active,eds,v,last,response,nak,dv,error;wire [63:0] out;wire [1:0] nw,cl;
wire [8:0] cost;wire [11:0] seq;wire [31:0] db;
integer beats=0;reg opened=0;
gen3_data_rx_x2 dut(clk,reset,start,1'b0,valid,data,pos,active,eds,out,nw,v,last,ready,cl,cost,response,nak,seq,dv,db,error,);
always @(posedge clk)if(!reset)begin
 if(error||nak)$fatal(1,"unexpected packet rejection");
 if(opened&&!v)$fatal(1,"synchronous packet RAM inserted a read bubble");
 if(v&&ready)begin beats<=beats+1;opened<=!last;end
end
task drive(input [63:0] d,input [1:0] p);begin @(negedge clk);data=d;pos=p;valid=1;end endtask
initial begin
 repeat(4)@(negedge clk);reset=0;start=1;@(negedge clk);start=0;
ROWS
 @(negedge clk);valid=0;repeat(12)@(negedge clk);ready=1;
 repeat(30)@(negedge clk);
 if(beats!=18)$fatal(1,"wrong packet beat count");
 $display("PASS read throughput");$finish;
end
endmodule'''.replace('ROWS', rows)
    simulate(tmp_path, bench, [GEN3 / 'gen3_data_rx_x2.sv'])


@pytest.mark.parametrize('words,slots', [(64, 2), (128, 4), (2048, 2)])
def test_x2_rx_buffer_geometry(tmp_path, words, slots):
    packets = [body(1, i + 1) for i in range(64)]
    # Small geometries need service time; this checks storage/descriptor wrap.
    stream = b''.join(tlp(i, p) + bytes(24) for i, p in enumerate(packets)) + bytes(16)
    got, responses, errors, eds, dllps = rx_trace(
        tmp_path, drive_stream(stream), words=words, slots=slots)
    assert got == packets and responses == [(i, 0) for i in range(64)]
    assert errors == eds == 0 and not dllps
