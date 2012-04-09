/*
	Copyright (c) 2011, T. Kroes <t.kroes@tudelft.nl>
	All rights reserved.

	Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

	- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
	- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
	- Neither the name of the TU Delft nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
	
	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#pragma once

#include "CudaUtilities.cuh"
#include "Geometry.cuh"
#include "Utilities.cuh"

namespace ExposureRender
{

#define KRNL_ESTIMATE_BLOCK_W		16
#define KRNL_ESTIMATE_BLOCK_H		8
#define KRNL_ESTIMATE_BLOCK_SIZE	KRNL_ESTIMATE_BLOCK_W * KRNL_ESTIMATE_BLOCK_H

KERNEL void KrnlComputeEstimate()
{
	const int X 	= blockIdx.x * blockDim.x + threadIdx.x;
	const int Y		= blockIdx.y * blockDim.y + threadIdx.y;

	if (X >= ((Tracer*)gpTracer)->FrameBuffer.Resolution[0] || Y >= ((Tracer*)gpTracer)->FrameBuffer.Resolution[1])
		return;

	((Tracer*)gpTracer)->FrameBuffer.CudaRunningEstimateXyza.Set(CumulativeMovingAverage(((Tracer*)gpTracer)->FrameBuffer.CudaRunningEstimateXyza.Get(X, Y), ((Tracer*)gpTracer)->FrameBuffer.CudaFrameEstimate.Get(X, Y), ((Tracer*)gpTracer)->NoIterations), X, Y);
}

void ComputeEstimate()
{
	const dim3 BlockDim(KRNL_ESTIMATE_BLOCK_W, KRNL_ESTIMATE_BLOCK_H);
	const dim3 GridDim((int)ceilf((float)gTracer.FrameBuffer.Resolution[0] / (float)BlockDim.x), (int)ceilf((float)gTracer.FrameBuffer.Resolution[1] / (float)BlockDim.y));

	LAUNCH_CUDA_KERNEL_TIMED((KrnlComputeEstimate<<<GridDim, BlockDim>>>()), "Compute running estimate");
}

}