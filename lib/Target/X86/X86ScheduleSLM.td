//=- X86ScheduleSLM.td - X86 Silvermont Scheduling -----------*- tablegen -*-=//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// This file defines the machine model for Intel Silvermont to support
// instruction scheduling and other instruction cost heuristics.
//
//===----------------------------------------------------------------------===//

def SLMModel : SchedMachineModel {
  // All x86 instructions are modeled as a single micro-op, and SLM can decode 2
  // instructions per cycle.
  let IssueWidth = 2;
  let MicroOpBufferSize = 32; // Based on the reorder buffer.
  let LoadLatency = 3;
  let MispredictPenalty = 10;
  let PostRAScheduler = 1;

  // For small loops, expand by a small factor to hide the backedge cost.
  let LoopMicroOpBufferSize = 10;

  // FIXME: SSE4 is unimplemented. This flag is set to allow
  // the scheduler to assign a default model to unrecognized opcodes.
  let CompleteModel = 0;
}

let SchedModel = SLMModel in {

// Silvermont has 5 reservation stations for micro-ops
def SLM_IEC_RSV0 : ProcResource<1>;
def SLM_IEC_RSV1 : ProcResource<1>;
def SLM_FPC_RSV0 : ProcResource<1> { let BufferSize = 1; }
def SLM_FPC_RSV1 : ProcResource<1> { let BufferSize = 1; }
def SLM_MEC_RSV  : ProcResource<1>;

// Many micro-ops are capable of issuing on multiple ports.
def SLM_IEC_RSV01  : ProcResGroup<[SLM_IEC_RSV0, SLM_IEC_RSV1]>;
def SLM_FPC_RSV01  : ProcResGroup<[SLM_FPC_RSV0, SLM_FPC_RSV1]>;

def SLMDivider      : ProcResource<1>;
def SLMFPMultiplier : ProcResource<1>;
def SLMFPDivider    : ProcResource<1>;

// Loads are 3 cycles, so ReadAfterLd registers needn't be available until 3
// cycles after the memory operand.
def : ReadAdvance<ReadAfterLd, 3>;

// Many SchedWrites are defined in pairs with and without a folded load.
// Instructions with folded loads are usually micro-fused, so they only appear
// as two micro-ops when queued in the reservation station.
// This multiclass defines the resource usage for variants with and without
// folded loads.
multiclass SLMWriteResPair<X86FoldableSchedWrite SchedRW,
                           list<ProcResourceKind> ExePorts,
                           int Lat, list<int> Res = [1], int UOps = 1,
                           int LoadLat = 3> {
  // Register variant is using a single cycle on ExePort.
  def : WriteRes<SchedRW, ExePorts> {
    let Latency = Lat;
    let ResourceCycles = Res;
    let NumMicroOps = UOps;
  }

  // Memory variant also uses a cycle on MEC_RSV and adds LoadLat cycles to
  // the latency (default = 3).
  def : WriteRes<SchedRW.Folded, !listconcat([SLM_MEC_RSV], ExePorts)> {
    let Latency = !add(Lat, LoadLat);
    let ResourceCycles = !listconcat([1], Res);
    let NumMicroOps = UOps;
  }
}

// A folded store needs a cycle on MEC_RSV for the store data, but it does not
// need an extra port cycle to recompute the address.
def : WriteRes<WriteRMW, [SLM_MEC_RSV]>;

def : WriteRes<WriteStore, [SLM_IEC_RSV01, SLM_MEC_RSV]>;
def : WriteRes<WriteLoad,  [SLM_MEC_RSV]> { let Latency = 3; }
def : WriteRes<WriteMove,  [SLM_IEC_RSV01]>;
def : WriteRes<WriteZero,  []>;

// Load/store MXCSR.
// FIXME: These are probably wrong. They are copy pasted from WriteStore/Load.
def : WriteRes<WriteSTMXCSR, [SLM_IEC_RSV01, SLM_MEC_RSV]>;
def : WriteRes<WriteLDMXCSR,  [SLM_MEC_RSV]> { let Latency = 3; }

// Treat misc copies as a move.
def : InstRW<[WriteMove], (instrs COPY)>;

defm : SLMWriteResPair<WriteALU,   [SLM_IEC_RSV01], 1>;
defm : SLMWriteResPair<WriteIMul,  [SLM_IEC_RSV1],  3>;
defm : SLMWriteResPair<WriteShift, [SLM_IEC_RSV0],  1>;
defm : SLMWriteResPair<WriteJump,  [SLM_IEC_RSV1],  1>;
defm : SLMWriteResPair<WriteCRC32, [SLM_IEC_RSV1],  3>;

defm : SLMWriteResPair<WriteCMOV,  [SLM_IEC_RSV01], 2, [2]>;
def  : WriteRes<WriteSETCC, [SLM_IEC_RSV01]>;
def  : WriteRes<WriteSETCCStore, [SLM_IEC_RSV01, SLM_MEC_RSV]> {
  // FIXME Latency and NumMicrOps?
  let ResourceCycles = [2,1];
}

// This is for simple LEAs with one or two input operands.
// The complex ones can only execute on port 1, and they require two cycles on
// the port to read all inputs. We don't model that.
def : WriteRes<WriteLEA, [SLM_IEC_RSV1]>;

// Bit counts.
defm : SLMWriteResPair<WriteBitScan, [SLM_IEC_RSV01], 10, [20], 10>;
defm : SLMWriteResPair<WriteLZCNT,   [SLM_IEC_RSV0], 3>;
defm : SLMWriteResPair<WriteTZCNT,   [SLM_IEC_RSV0], 3>;
defm : SLMWriteResPair<WritePOPCNT,  [SLM_IEC_RSV0], 3>;

// BMI1 BEXTR, BMI2 BZHI
// NOTE: These don't exist on Silvermont. Ports are guesses.
defm : SLMWriteResPair<WriteBEXTR, [SLM_IEC_RSV0], 1>;
defm : SLMWriteResPair<WriteBZHI, [SLM_IEC_RSV0], 1>;

// This is quite rough, latency depends on the dividend.
defm : SLMWriteResPair<WriteIDiv, [SLM_IEC_RSV01, SLMDivider], 25, [1,25], 1, 4>;

// Scalar and vector floating point.
def  : WriteRes<WriteFStore,       [SLM_FPC_RSV01, SLM_MEC_RSV]>;
def  : WriteRes<WriteFLoad,        [SLM_MEC_RSV]> { let Latency = 3; }
def  : WriteRes<WriteFMove,        [SLM_FPC_RSV01]>;

defm : SLMWriteResPair<WriteFAdd,   [SLM_FPC_RSV1], 3>;
defm : SLMWriteResPair<WriteFAddY,  [SLM_FPC_RSV1], 3>;
defm : SLMWriteResPair<WriteFCmp,   [SLM_FPC_RSV1], 3>;
defm : SLMWriteResPair<WriteFCmpY,  [SLM_FPC_RSV1], 3>;
defm : SLMWriteResPair<WriteFCom,   [SLM_FPC_RSV1], 3>;
defm : SLMWriteResPair<WriteFMul,   [SLM_FPC_RSV0, SLMFPMultiplier], 5, [1,2]>;
defm : SLMWriteResPair<WriteFMulY,  [SLM_FPC_RSV0, SLMFPMultiplier], 5, [1,2]>;
defm : SLMWriteResPair<WriteFDiv,   [SLM_FPC_RSV0, SLMFPDivider], 34, [1,34]>;
defm : SLMWriteResPair<WriteFDivY,  [SLM_FPC_RSV0, SLMFPDivider], 34, [1,34]>;
defm : SLMWriteResPair<WriteFRcp,   [SLM_FPC_RSV0], 5>;
defm : SLMWriteResPair<WriteFRcpY,  [SLM_FPC_RSV0], 5>;
defm : SLMWriteResPair<WriteFRsqrt, [SLM_FPC_RSV0], 5>;
defm : SLMWriteResPair<WriteFRsqrtY,[SLM_FPC_RSV0], 5>;
defm : SLMWriteResPair<WriteFSqrt,  [SLM_FPC_RSV0], 15>;
defm : SLMWriteResPair<WriteFSqrtY, [SLM_FPC_RSV0], 15>;
defm : SLMWriteResPair<WriteCvtF2I, [SLM_FPC_RSV01], 4>;
defm : SLMWriteResPair<WriteCvtI2F, [SLM_FPC_RSV01], 4>;
defm : SLMWriteResPair<WriteCvtF2F, [SLM_FPC_RSV01], 4>;
defm : SLMWriteResPair<WriteFSign,  [SLM_FPC_RSV01], 1>;
defm : SLMWriteResPair<WriteFLogic, [SLM_FPC_RSV01], 1>;
defm : SLMWriteResPair<WriteFLogicY, [SLM_FPC_RSV01], 1>;
defm : SLMWriteResPair<WriteFShuffle,  [SLM_FPC_RSV0], 1>;
defm : SLMWriteResPair<WriteFShuffleY, [SLM_FPC_RSV0], 1>;
defm : SLMWriteResPair<WriteFVarShuffle, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteFVarShuffleY,[SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteFBlend,  [SLM_FPC_RSV0],  1>;
def  : WriteRes<WriteCvtF2FSt, [SLM_FPC_RSV01, SLM_MEC_RSV]>;

// Vector integer operations.
def  : WriteRes<WriteVecStore,       [SLM_FPC_RSV01, SLM_MEC_RSV]>;
def  : WriteRes<WriteVecLoad,        [SLM_MEC_RSV]> { let Latency = 3; }
def  : WriteRes<WriteVecMove,        [SLM_FPC_RSV01]>;

defm : SLMWriteResPair<WriteVecShift, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteVecLogic, [SLM_FPC_RSV01], 1>;
defm : SLMWriteResPair<WriteVecLogicY,[SLM_FPC_RSV01], 1>;
defm : SLMWriteResPair<WriteVecALU,   [SLM_FPC_RSV01],  1>;
defm : SLMWriteResPair<WriteVecIMul,  [SLM_FPC_RSV0],   4>;
// FIXME: The below is closer to correct, but caused some perf regressions.
//defm : SLMWriteResPair<WritePMULLD,  [SLM_FPC_RSV0],   11, [11], 7>;
defm : SLMWriteResPair<WritePMULLD,  [SLM_FPC_RSV0],   4>;
defm : SLMWriteResPair<WriteShuffle,  [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteVarShuffle,  [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteBlend,  [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteMPSAD,  [SLM_FPC_RSV0],  7>;
defm : SLMWriteResPair<WritePSADBW, [SLM_FPC_RSV0],  4>;
defm : SLMWriteResPair<WritePHMINPOS,  [SLM_FPC_RSV0],   4>;

// Vector insert/extract operations.
defm : SLMWriteResPair<WriteVecInsert, [SLM_FPC_RSV0],  1>;

def  : WriteRes<WriteVecExtract, [SLM_FPC_RSV0]>;
def  : WriteRes<WriteVecExtractSt, [SLM_FPC_RSV0, SLM_MEC_RSV]> {
  let Latency = 4;
  let NumMicroOps = 2;
  let ResourceCycles = [1, 2];
}

////////////////////////////////////////////////////////////////////////////////
// Horizontal add/sub  instructions.
////////////////////////////////////////////////////////////////////////////////

defm : SLMWriteResPair<WriteFHAdd,   [SLM_FPC_RSV01], 3, [2]>;
defm : SLMWriteResPair<WriteFHAddY,  [SLM_FPC_RSV01], 3, [2]>;
defm : SLMWriteResPair<WritePHAdd,   [SLM_FPC_RSV01], 1>;

// String instructions.
// Packed Compare Implicit Length Strings, Return Mask
def : WriteRes<WritePCmpIStrM, [SLM_FPC_RSV0]> {
  let Latency = 13;
  let ResourceCycles = [13];
}
def : WriteRes<WritePCmpIStrMLd, [SLM_FPC_RSV0, SLM_MEC_RSV]> {
  let Latency = 13;
  let ResourceCycles = [13, 1];
}

// Packed Compare Explicit Length Strings, Return Mask
def : WriteRes<WritePCmpEStrM, [SLM_FPC_RSV0]> {
  let Latency = 17;
  let ResourceCycles = [17];
}
def : WriteRes<WritePCmpEStrMLd, [SLM_FPC_RSV0, SLM_MEC_RSV]> {
  let Latency = 17;
  let ResourceCycles = [17, 1];
}

// Packed Compare Implicit Length Strings, Return Index
def : WriteRes<WritePCmpIStrI, [SLM_FPC_RSV0]> {
  let Latency = 17;
  let ResourceCycles = [17];
}
def : WriteRes<WritePCmpIStrILd, [SLM_FPC_RSV0, SLM_MEC_RSV]> {
  let Latency = 17;
  let ResourceCycles = [17, 1];
}

// Packed Compare Explicit Length Strings, Return Index
def : WriteRes<WritePCmpEStrI, [SLM_FPC_RSV0]> {
  let Latency = 21;
  let ResourceCycles = [21];
}
def : WriteRes<WritePCmpEStrILd, [SLM_FPC_RSV0, SLM_MEC_RSV]> {
  let Latency = 21;
  let ResourceCycles = [21, 1];
}

// MOVMSK Instructions.
def : WriteRes<WriteFMOVMSK, [SLM_FPC_RSV1]> { let Latency = 4; }
def : WriteRes<WriteVecMOVMSK, [SLM_FPC_RSV1]> { let Latency = 4; }
def : WriteRes<WriteMMXMOVMSK, [SLM_FPC_RSV1]> { let Latency = 4; }

// AES Instructions.
def : WriteRes<WriteAESDecEnc, [SLM_FPC_RSV0]> {
  let Latency = 8;
  let ResourceCycles = [5];
}
def : WriteRes<WriteAESDecEncLd, [SLM_FPC_RSV0, SLM_MEC_RSV]> {
  let Latency = 8;
  let ResourceCycles = [5, 1];
}

def : WriteRes<WriteAESIMC, [SLM_FPC_RSV0]> {
  let Latency = 8;
  let ResourceCycles = [5];
}
def : WriteRes<WriteAESIMCLd, [SLM_FPC_RSV0, SLM_MEC_RSV]> {
  let Latency = 8;
  let ResourceCycles = [5, 1];
}

def : WriteRes<WriteAESKeyGen, [SLM_FPC_RSV0]> {
  let Latency = 8;
  let ResourceCycles = [5];
}
def : WriteRes<WriteAESKeyGenLd, [SLM_FPC_RSV0, SLM_MEC_RSV]> {
  let Latency = 8;
  let ResourceCycles = [5, 1];
}

// Carry-less multiplication instructions.
def : WriteRes<WriteCLMul, [SLM_FPC_RSV0]> {
  let Latency = 10;
  let ResourceCycles = [10];
}
def : WriteRes<WriteCLMulLd, [SLM_FPC_RSV0, SLM_MEC_RSV]> {
  let Latency = 10;
  let ResourceCycles = [10, 1];
}


def : WriteRes<WriteSystem,     [SLM_FPC_RSV0]> { let Latency = 100; }
def : WriteRes<WriteMicrocoded, [SLM_FPC_RSV0]> { let Latency = 100; }
def : WriteRes<WriteFence, [SLM_MEC_RSV]>;
def : WriteRes<WriteNop, []>;

// AVX/FMA is not supported on that architecture, but we should define the basic
// scheduling resources anyway.
def  : WriteRes<WriteIMulH, [SLM_FPC_RSV0]>;
defm : SLMWriteResPair<WriteFBlendY, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteVarBlend, [SLM_FPC_RSV0], 1>;
defm : SLMWriteResPair<WriteFVarBlend, [SLM_FPC_RSV0], 1>;
defm : SLMWriteResPair<WriteFVarBlendY, [SLM_FPC_RSV0], 1>;
defm : SLMWriteResPair<WriteFShuffle256, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteFVarShuffle256, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteShuffle256, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteVarShuffle256, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteVarVecShift, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteFMA, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteFMAS, [SLM_FPC_RSV0],  1>;
defm : SLMWriteResPair<WriteFMAY, [SLM_FPC_RSV0],  1>;

// Instruction overrides

def SLMriteResGroup1 : SchedWriteRes<[SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 69;
  let NumMicroOps = 1;
  let ResourceCycles = [1,69];
}
def: InstRW<[SLMriteResGroup1], (instregex "(V?)DIVPDrr")>;

def SLMriteResGroup2 : SchedWriteRes<[SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 39;
  let NumMicroOps = 1;
  let ResourceCycles = [1,39];
}
def: InstRW<[SLMriteResGroup2], (instregex "(V?)DIVPSrr")>;

def SLMriteResGroup3 : SchedWriteRes<[SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 34;
  let NumMicroOps = 1;
  let ResourceCycles = [1,32];
}
def: InstRW<[SLMriteResGroup3], (instregex "(V?)DIVSDrr")>;

def SLMriteResGroup4 : SchedWriteRes<[SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 19;
  let NumMicroOps = 1;
  let ResourceCycles = [1,17];
}
def: InstRW<[SLMriteResGroup4], (instregex "(V?)DIVSSrr")>;

def SLMriteResGroup5 : SchedWriteRes<[SLM_MEC_RSV,SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 72;
  let NumMicroOps = 1;
  let ResourceCycles = [1,1,69];
}
def: InstRW<[SLMriteResGroup5], (instregex "(V?)DIVPDrm")>;

def SLMriteResGroup6 : SchedWriteRes<[SLM_MEC_RSV,SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 42;
  let NumMicroOps = 1;
  let ResourceCycles = [1,1,39];
}
def: InstRW<[SLMriteResGroup6], (instregex "(V?)DIVPSrm")>;

def SLMriteResGroup7 : SchedWriteRes<[SLM_MEC_RSV,SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 37;
  let NumMicroOps = 1;
  let ResourceCycles = [1,1,32];
}
def: InstRW<[SLMriteResGroup7], (instregex "(V?)DIVSDrm")>;

def SLMriteResGroup8 : SchedWriteRes<[SLM_MEC_RSV,SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 22;
  let NumMicroOps = 1;
  let ResourceCycles = [1,1,17];
}
def: InstRW<[SLMriteResGroup8], (instregex "(V?)DIVSSrm")>;

def SLMriteResGroup9 : SchedWriteRes<[SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 71;
  let NumMicroOps = 1;
  let ResourceCycles = [1,70];
}
def: InstRW<[SLMriteResGroup9], (instregex "(V?)SQRTPDr")>;

def SLMriteResGroup10 : SchedWriteRes<[SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 41;
  let NumMicroOps = 1;
  let ResourceCycles = [1,40];
}
def: InstRW<[SLMriteResGroup10], (instregex "(V?)SQRTPSr")>;

def SLMriteResGroup11 : SchedWriteRes<[SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 35;
  let NumMicroOps = 1;
  let ResourceCycles = [1,35];
}
def: InstRW<[SLMriteResGroup11], (instregex "(V?)SQRTSDr")>;

def SLMriteResGroup12 : SchedWriteRes<[SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 20;
  let NumMicroOps = 1;
  let ResourceCycles = [1,20];
}
def: InstRW<[SLMriteResGroup12], (instregex "(V?)SQRTSSr")>;

def SLMriteResGroup13 : SchedWriteRes<[SLM_MEC_RSV,SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 74;
  let NumMicroOps = 1;
  let ResourceCycles = [1,1,70];
}
def: InstRW<[SLMriteResGroup13], (instregex "(V?)SQRTPDm")>;

def SLMriteResGroup14 : SchedWriteRes<[SLM_MEC_RSV,SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 44;
  let NumMicroOps = 1;
  let ResourceCycles = [1,1,40];
}
def: InstRW<[SLMriteResGroup14], (instregex "(V?)SQRTPSm")>;

def SLMriteResGroup15 : SchedWriteRes<[SLM_MEC_RSV,SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 38;
  let NumMicroOps = 1;
  let ResourceCycles = [1,1,35];
}
def: InstRW<[SLMriteResGroup15], (instregex "(V?)SQRTSDm")>;

def SLMriteResGroup16 : SchedWriteRes<[SLM_MEC_RSV,SLM_FPC_RSV0,SLMFPDivider]> {
  let Latency = 23;
  let NumMicroOps = 1;
  let ResourceCycles = [1,1,20];
}
def: InstRW<[SLMriteResGroup16], (instregex "(V?)SQRTSSm")>;

} // SchedModel
