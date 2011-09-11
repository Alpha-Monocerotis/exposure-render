
#include "VolumeTracer.cuh"

#include "Filter.h"
#include "Scene.h"
#include "Material.h"

texture<float, 3, cudaReadModeElementType>	gTexDensity;
texture<float, 3, cudaReadModeElementType>	gTexExtinction;

void BindDensityVolume(float* pDensityBuffer, cudaExtent Size)
{
	cudaArray* gpDensity = NULL;

	// create 3D array
	cudaChannelFormatDesc ChannelDesc = cudaCreateChannelDesc<float>();
	cudaMalloc3DArray(&gpDensity, &ChannelDesc, Size);

	// copy data to 3D array
	cudaMemcpy3DParms copyParams	= {0};
	copyParams.srcPtr				= make_cudaPitchedPtr(pDensityBuffer, Size.width * sizeof(float), Size.width, Size.height);
	copyParams.dstArray				= gpDensity;
	copyParams.extent				= Size;
	copyParams.kind					= cudaMemcpyHostToDevice;
	cudaMemcpy3D(&copyParams);

	// Set texture parameters
	gTexDensity.normalized		= true;
	gTexDensity.filterMode		= cudaFilterModeLinear;      
	gTexDensity.addressMode[0]	= cudaAddressModeClamp;  
	gTexDensity.addressMode[1]	= cudaAddressModeClamp;
	gTexDensity.addressMode[2]	= cudaAddressModeClamp;

	// Bind array to 3D texture
	cudaBindTextureToArray(gTexDensity, gpDensity, ChannelDesc);
}

void BindExtinctionVolume(float* pExtinctionBuffer, cudaExtent Size)
{
	cudaArray* gpExtinction = NULL;

	// create 3D array
	cudaChannelFormatDesc ChannelDesc = cudaCreateChannelDesc<float>();
	cudaMalloc3DArray(&gpExtinction, &ChannelDesc, Size);

	// copy data to 3D array
	cudaMemcpy3DParms copyParams	= {0};
	copyParams.srcPtr				= make_cudaPitchedPtr(pExtinctionBuffer, Size.width * sizeof(float), Size.width, Size.height);
	copyParams.dstArray				= gpExtinction;
	copyParams.extent				= Size;
	copyParams.kind					= cudaMemcpyHostToDevice;
	cudaMemcpy3D(&copyParams);

	// Set texture parameters
	gTexExtinction.normalized		= true;
	gTexExtinction.filterMode		= cudaFilterModePoint;      
	gTexExtinction.addressMode[0]	= cudaAddressModeClamp;  
	gTexExtinction.addressMode[1]	= cudaAddressModeClamp;
	gTexExtinction.addressMode[2]	= cudaAddressModeClamp;

	// Bind array to 3D texture
	cudaBindTextureToArray(gTexExtinction, gpExtinction, ChannelDesc);
}

DEV float Density(CScene* pDevScene, const Vec3f& P)
{
	return tex3D(gTexDensity, P.x / pDevScene->m_BoundingBox.LengthX(), P.y / pDevScene->m_BoundingBox.LengthY(), P.z /  pDevScene->m_BoundingBox.LengthZ());
}

DEV CColorRgbHdr GetOpacity(CScene* pDevScene, const float& D)
{
	const float Opacity = pDevScene->m_TransferFunctions.m_Opacity.F(D).r;
	return CColorRgbHdr(Opacity, Opacity, Opacity);
}

DEV CColorRgbHdr GetDiffuse(CScene* pDevScene, const float& D)
{
	return pDevScene->m_TransferFunctions.m_Diffuse.F(D);
}

DEV CColorRgbHdr GetSpecular(CScene* pDevScene, const float& D)
{
	return pDevScene->m_TransferFunctions.m_Specular.F(D);
}

DEV CColorRgbHdr GetEmission(CScene* pDevScene, const float& D)
{
	return pDevScene->m_TransferFunctions.m_Emission.F(D);
}

// Computes the attenuation through the volume
DEV CColorXyz Transmittance(CScene* pDevScene, const Vec3f& P, const Vec3f& D, const float& MaxT, const float& StepSize, CCudaRNG& RNG)
{
	// Near and far intersections with volume axis aligned bounding box
	float NearT = 0.0f, FarT = FLT_MAX;

	if (!pDevScene->m_BoundingBox.Intersect(CRay(P, D, 0.0f, MaxT), &NearT, &FarT))
		return SPEC_WHITE;

	CColorXyz Lt = SPEC_WHITE;

	NearT += RNG.Get1() * StepSize;

	// Accumulate
	while (NearT < MaxT)
	{
		// Determine sample point
		const Vec3f SP = P + D * (NearT);

		// Fetch density
		const float D = Density(pDevScene, SP);
		
		// Get shadow opacity
		const float		Opacity = GetOpacity(pDevScene, D).r;
		const CColorXyz	Color	= GetDiffuse(pDevScene, D).r;

		if (Opacity > 0.0f)
		{
			// Compute chromatic attenuation
// 			Lt.c[0] *= expf(-(Opacity * (1.0f - Color.c[0]) * StepSize));
// 			Lt.c[1] *= expf(-(Opacity * (1.0f - Color.c[1]) * StepSize));
// 			Lt.c[2] *= expf(-(Opacity * (1.0f - Color.c[2]) * StepSize));

			Lt.c[0] *= expf(-(Opacity * StepSize));
			Lt.c[1] *= expf(-(Opacity * StepSize));
			Lt.c[2] *= expf(-(Opacity * StepSize));

			// Exit if eye transmittance is very small
			if (Lt.y() < 0.05f)
				break;
		}

		// Increase extent
		NearT += StepSize;
	}

	return Lt;
}

// Estimates direct lighting
DEV CColorXyz EstimateDirectLight(CScene* pDevScene, CLight& Light, CLightingSample& LS, const Vec3f& Wo, const Vec3f& Pe, const Vec3f& N, CCudaRNG& Rnd, const float& StepSize)
{
	return SPEC_WHITE;

	// Accumulated radiance (Ld), exitant radiance from light source (Li), attenuation through participating medium along light ray (Tr)
	CColorXyz Ld = SPEC_BLACK, Li = SPEC_BLACK, Tr = SPEC_BLACK;
	
	float D = Density(pDevScene, Pe);

	CBSDF Bsdf(N, Wo, GetDiffuse(pDevScene, D).ToXYZ(), GetSpecular(pDevScene, D).ToXYZ(), 1.5f, pDevScene->m_TransferFunctions.m_Roughness.F(D).r);

	// Light/shadow ray
	CRay Rl; 

	// Light probability
	float LightPdf = 1.0f, BsdfPdf = 1.0f;
	
	// Incident light direction
	Vec3f Wi;

	CColorXyz F = SPEC_BLACK;
	
	// Sample the light source
 	Li = Light.SampleL(Pe, Rl, LightPdf, LS);
	
	F = Bsdf.F(Wo, -Rl.m_D); 

	BsdfPdf	= Bsdf.Pdf(Wo, -Rl.m_D);
//	BsdfPdf = Dot(Wi, N);
	

	// Sample the light with MIS
	if (!Li.IsBlack() && LightPdf > 0.0f && BsdfPdf > 0.0f)
	{
		// Compute tau
		Tr = Transmittance(pDevScene, Rl.m_O, Rl.m_D, Length(Rl.m_O - Pe), StepSize, Rnd);
		
		// Attenuation due to volume
		Li *= Tr;

		// Compute MIS weight
		const float Weight = 1.0f;//PowerHeuristic(1.0f, LightPdf, 1.0f, BsdfPdf);
 
		// Add contribution
		Ld += F * Li * (Weight / LightPdf);
	}
	
	// Compute tau

	/**/	
	// Attenuation due to volume
	

//	Ld = Li * Transmittance(pDevScene, Rl.m_O, Rl.m_D, Length(Rl.m_O - Pe), StepSize, Rnd);

	/**/

	/*
	// Sample the BRDF with MIS
	F = Bsdf.SampleF(Wo, Wi, BsdfPdf, LS.m_BsdfSample);
	
//	Wi = CosineWeightedHemisphere(Rnd.Get2(), N);

//	BsdfPdf = Dot(Wi, N);

	CLight* pNearestLight = NULL;

	Vec2f UV;

	if (!F.IsBlack())
	{
		float MaxT = INF_MAX;

		// Compute virtual light point
		const Vec3f Pl = Pe + (MaxT * Wi);

		if (NearestLight(pScene, Pe, Wi, 0.0f, MaxT, pNearestLight, NULL, &UV, &LightPdf))
		{
			if (LightPdf > 0.0f && BsdfPdf > 0.0f) 
			{
				// Add light contribution from BSDF sampling
				const float Weight = PowerHeuristic(1.0f, BsdfPdf, 1.0f, LightPdf);
				 
				// Get exitant radiance from light source
				Li = pNearestLight->Le(UV, pScene->m_Materials, pScene->m_Textures, pScene->m_Bitmaps);

				if (!Li.IsBlack())
				{
					// Scale incident radiance by attenuation through volume
					Tr = Transmittance(pScene, Pe, Wi, 1.0f, StepSize, Rnd);

					// Attenuation due to volume
					Li *= Tr;

					// Contribute
					Ld += F * Li * AbsDot(Wi, N) * Weight / BsdfPdf;
				}
			}
		}
	}
	*/

	return Ld;
}

// Uniformly samples one light
DEV CColorXyz UniformSampleOneLight(CScene* pDevScene, const Vec3f& Wo, const Vec3f& Pe, const Vec3f& N, CCudaRNG& Rnd, const float& StepSize)
{
 	if (pDevScene->m_Lighting.m_NoLights == 0)
 		return SPEC_RED;

	CLightingSample LS;

	// Create light sampler
	LS.LargeStep(Rnd);

	// Choose which light to sample
	const int WhichLight = (int)floorf(LS.m_LightNum * (float)pDevScene->m_Lighting.m_NoLights);

	// Get the light
	CLight& Light = pDevScene->m_Lighting.m_Lights[WhichLight];

	// Return estimated direct light
	return (float)pDevScene->m_Lighting.m_NoLights * EstimateDirectLight(pDevScene, Light, LS, Wo, Pe, N, Rnd, StepSize);
}

// Computes the local gradient
DEV Vec3f ComputeGradient(CScene* pDevScene, const Vec3f& P)
{
	Vec3f Normal;

	const float Delta = pDevScene->m_Spacing.Min();

	Vec3f X(Delta, 0.0f, 0.0f), Y(0.0f, Delta, 0.0f), Z(0.0f, 0.0f, Delta);

	Normal.x = 0.5f * (float)(Density(pDevScene, P + X) - Density(pDevScene, P - X));
	Normal.y = 0.5f * (float)(Density(pDevScene, P + Y) - Density(pDevScene, P - Y));
	Normal.z = 0.5f * (float)(Density(pDevScene, P + Z) - Density(pDevScene, P - Z));

	return Normalize(-Normal);
}

HOD float PhaseHG(const Vec3f& W, const Vec3f& Wp, float G)
{
	float CosTheta = Dot(W, Wp);
	return 1.0f / (4.0f * PI_F) * (1.0f - G * G) / powf(1.0f + G * G - 2.0f * G * CosTheta, 1.5f);
}

HOD Vec3f SampleHG(const Vec3f& W, float G, const Vec2f& U)
{
	float CosTheta;

	if (fabsf(G) < 1e-3)
	{
		CosTheta = 1.0f - 2.0f * U.x;
	}
	else
	{
		float SqrtTerm = (1.0f - G * G) / (1.0f - G + 2.0f * G * U.x);
		CosTheta = (1.0f + G * G - SqrtTerm * SqrtTerm) / (2.0f * G);
	}

	float SinTheta = sqrtf(max(0.f, 1.f - CosTheta * CosTheta));
	float Phi = 2.f * PI_F * U.y;
	Vec3f V1, V2;
	CoordinateSystem(W, &V1, &V2);
	return SphericalDirection(SinTheta, CosTheta, Phi, V1, V2, W);
}

HOD float PdfHG(const Vec3f& W, const Vec3f& Wp, float G)
{
	return PhaseHG(W, Wp, G);
}

DEV inline bool SampleDistanceRM(CRay& R, CCudaRNG& RNG, CVolumePoint& VP, CScene* pDevScene, int Component)
{
	float MinT = 0.0f, MaxT = 0.0f;

	if (!pDevScene->m_BoundingBox.Intersect(R, &MinT, &MaxT))
		return false;

	MinT = max(MinT, R.m_MinT);
	MaxT = min(MaxT, R.m_MaxT);

	float S		= -log(RNG.Get1()) / pDevScene->m_DensityScale;
	float Dt	= 10.0f * (1.0f / (float)pDevScene->m_Resolution.GetResXYZ().Max()), Sum = 0.0f, SigmaT = 0.0f, D = 0.0f;

	Vec3f samplePos; 

	MinT += RNG.Get1() * Dt;

	while (Sum < S)
	{
		samplePos = R.m_O + MinT * R.m_D;

		if (MinT > MaxT)
			return false;
		
		D = Density(pDevScene, samplePos);

		SigmaT	= 100.0f * GetOpacity(pDevScene, D)[Component];// * GetDiffuse(pDevScene, D)[Component];
		Sum		+= SigmaT * Dt;
		MinT	+= Dt;
	}

	VP.m_Transmittance.c[Component]	= 0.5f;
	VP.m_P							= samplePos;
	VP.m_D							= D;

	return true;
}

DEV inline bool FreePathRM(CRay& R, CCudaRNG& RNG, CVolumePoint& VP, CScene* pDevScene, int Component)
{
	float MinT = 0.0f, MaxT = 0.0f;

	if (!pDevScene->m_BoundingBox.Intersect(R, &MinT, &MaxT))
		return false;

	MinT = max(MinT, R.m_MinT);
//	MaxT = min(MaxT, R.m_MaxT);

	float S		= -log(RNG.Get1()) / pDevScene->m_DensityScale;
	float Dt	= 10.0f * (1.0f / (float)pDevScene->m_Resolution.GetResXYZ().Max()), Sum = 0.0f, SigmaT = 0.0f, D = 0.0f;

	Vec3f samplePos; 

	MinT += RNG.Get1() * Dt;

	while (Sum < S)
	{
		samplePos = R.m_O + MinT * R.m_D;

		// Free path, no collisions in between
		if (MinT > R.m_MaxT)
			break;
		
		D = Density(pDevScene, samplePos);

		SigmaT	= 100.0f * GetOpacity(pDevScene, D)[Component];// * GetDiffuse(pDevScene, D)[Component];
		Sum		+= SigmaT * Dt;
		MinT	+= Dt;
	}

	if (MinT < R.m_MaxT)
		return false;

	VP.m_Transmittance.c[Component]	= 0.5f;
	VP.m_P							= samplePos;
	VP.m_D							= D;

	return true;
}

// Trace volume with single scattering
KERNEL void KrnlSS(CScene* pDevScene, curandStateXORWOW_t* pDevRandomStates, CColorXyz* pDevEstFrameXyz)
{
	const int X = (blockIdx.x * blockDim.x) + threadIdx.x;		// Get global y
	const int Y	= (blockIdx.y * blockDim.y) + threadIdx.y;		// Get global x

	// Compute sample ID
	const int SID = (Y * (gridDim.x * blockDim.x)) + X;

	// Exit if beyond kernel boundaries
	if (X >= pDevScene->m_Camera.m_Film.m_Resolution.GetResX() || Y >= pDevScene->m_Camera.m_Film.m_Resolution.GetResY())
		return;

	// Init random number generator
	CCudaRNG RNG(&pDevRandomStates[SID]);

	CRay Re, Rl;
	
	// Generate the camera ray
	pDevScene->m_Camera.GenerateRay(Vec2f(X, Y), RNG.Get2(), Re.m_O, Re.m_D);

	// Eye attenuation (Le), accumulated color through volume (Lv), unattenuated light from light source (Li), attenuated light from light source (Ld), and BSDF value (F)
	CColorXyz PathThroughput	= SPEC_WHITE;
	CColorXyz Li				= SPEC_BLACK;
	CColorXyz Lv				= SPEC_BLACK;
	CColorXyz F					= SPEC_BLACK;

	int NoScatteringEvents = 0, RussianRouletteDepth = 2; 

	Re.m_MinT	= 0.0f;
	Re.m_MaxT	= RAY_MAX;

	// Continue probability (Pc) Light probability (LightPdf) Bsdf probability (BsdfPdf)
	float Pc = 0.5f, LightPdf = 1.0f, BsdfPdf = 1.0f;

	// Eye point (Pe), light sample point (Pl), Gradient (G), normalized gradient (Gn), reversed eye direction (Wo), incident direction (Wi), new direction (W)
	Vec3f Pe, Pl, G, Gn, Wo, Wi, W;

	// Choose color component to sample
	int CC1 = floorf(RNG.Get1() * 3.0f);

	// Walk along the eye ray with ray marching
	while (NoScatteringEvents < pDevScene->m_MaxNoBounces)
	{
		CVolumePoint VP;

		// Sample distance
		if (SampleDistanceRM(Re, RNG, VP, pDevScene, CC1))
		{
// 			if (VP.m_Transmittance.y() > 0.0f)
//			PathThroughput.c[CC1] *= VP.m_Transmittance.c[CC1];

			// Compute gradient (G) and normalized gradient (Gn)
  			G	= ComputeGradient(pDevScene, VP.m_P);
  			Gn	= Normalize(G);
 			Wo	= Normalize(-Re.m_D);

			Pe = VP.m_P;

			CLightingSample LS;
			LS.LargeStep(RNG);

			Li = pDevScene->m_Lighting.m_Lights[(int)floorf(RNG.Get1() * (float)pDevScene->m_Lighting.m_NoLights)].SampleL(Pe, Rl, LightPdf, LS);

//			Pl = pDevScene->m_BoundingBox.GetCenter() + pDevScene->m_Lighting.m_Lights[0].m_Distance * Vec3f(sinf(pDevScene->m_Lighting.m_Lights[0].m_Theta), sinf(pDevScene->m_Lighting.m_Lights[0].m_Phi), cosf(pDevScene->m_Lighting.m_Lights[0].m_Theta));
//			Pl = pBoundingBox->GetCenter() + UniformSampleSphere(RNG.Get2()) * Vec3f(1000.0f);

			// LightPdf = powf((Pe - Pl).Length(), 2.0f);

//			Rl = CRay(Pl, Normalize(Pe - Pl), 0.0f, (Pe - Pl).Length());

 			if (!Li.IsBlack() && LightPdf > 0.0f && FreePathRM(Rl, RNG, VP, pDevScene, CC1))
 			{
 				Li /= LightPdf;
 				Lv.c[CC1] += PathThroughput.c[CC1] * Li.c[CC1] * PhaseHG(Wo, Rl.m_D, pDevScene->m_PhaseG);// * VP.m_Transmittance.c[CC1];// * ;
 			}

			W = Normalize(SampleHG(Wo, pDevScene->m_PhaseG, RNG.Get2()));
//			W = UniformSampleSphere(RNG.Get2());
//			W = UniformSampleHemisphere(RNG.Get2(), Gn);

			// Configure eye ray
			Re = CRay(VP.m_P, W, 0.0f, RAY_MAX);

			// Russian roulette
			if (NoScatteringEvents >= RussianRouletteDepth)
			{
				if (RNG.Get1() > Pc)
					break;
				else
					PathThroughput.c[CC1] /= Pc;
			}

//			PathThroughput.c[CC1] /= 4.0f * PI_F;
//			PathThroughput.c[CC1] /= PhaseHG(Wo, Rl.m_D, PhaseG);

			// Add scattering event
			NoScatteringEvents++;
		}
		else
		{
			break;
		}
	}

//  	if (pBoundingBox->Intersect(Re))
//  		Lv += SPEC_WHITE;


	pDevEstFrameXyz[Y * (int)pDevScene->m_Camera.m_Film.m_Resolution.GetResX() + X].c[CC1] = Lv.c[CC1] / fmaxf(1.0f, NoScatteringEvents);
}

// Traces the volume
void RenderVolume(CScene* pScene, CScene* pDevScene, curandStateXORWOW_t* pDevRandomStates, CColorXyz* pDevEstFrameXyz)
{
	const dim3 KernelBlock(32, 8);
	const dim3 KernelGrid((int)ceilf((float)pScene->m_Camera.m_Film.m_Resolution.GetResX() / (float)KernelBlock.x), (int)ceilf((float)pScene->m_Camera.m_Film.m_Resolution.GetResY() / (float)KernelBlock.y));
	
	// Execute kernel
	KrnlSS<<<KernelGrid, KernelBlock>>>(pDevScene, pDevRandomStates, pDevEstFrameXyz);
}