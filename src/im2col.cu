#include "common.h"

template <typename Dtype>
__global__ void im2col_gpu_kernel(const int n, const Dtype* data_im,
								  const int height, const int width, const int ksize, const int pad,
								  const int stride, const int height_col, const int width_col,
								  Dtype* data_col) 
{
	CUDA_KERNEL_LOOP(index, n) {
		int w_out = index % width_col;
		int h_index = index / width_col;
		int h_out = h_index % height_col;
		int channel_in = h_index / height_col;
		int channel_out = channel_in * ksize * ksize;
		int h_in = h_out * stride - pad;
		int w_in = w_out * stride - pad;
		Dtype* data_col_ptr = data_col;
		data_col_ptr += (channel_out * height_col + h_out) * width_col + w_out;
		const Dtype* data_im_ptr = data_im;
		data_im_ptr += (channel_in * height + h_in) * width + w_in;
		for (int i = 0; i < ksize; ++i) {
			for (int j = 0; j < ksize; ++j) {
				int h = h_in + i;
				int w = w_in + j;
				*data_col_ptr = (h >= 0 && w >= 0 && h < height && w < width) ?
					data_im_ptr[i * width + j] : 0;
				data_col_ptr += height_col * width_col;
			}
		}
	}
}

//__global__ void im2col_gpu_kernel(const int n, const float* data_im,
//    const int height, const int width, const int ksize, const int pad,
//    const int stride, const int height_col, const int width_col,
//    float* data_col) {
//  CUDA_KERNEL_LOOP(op_idx, n) {
//	int index = op_idx;
//    int w_out = index % width_col;
//
//    index /= width_col;
//    int h_out = index % height_col;
//    int channel_in = index / height_col;
//    int channel_out = channel_in * ksize * ksize;
//    int h_in = h_out * stride - pad;
//    int w_in = w_out * stride - pad;
//	
//    float* temp_col = data_col+ (channel_out * height_col + h_out) * width_col + w_out;
//    const float* temp_img = data_im + (channel_in * height + h_in) * width + w_in;
//	
//    for (int i = 0; i < ksize; ++i) {
//      for (int j = 0; j < ksize; ++j) {
//        int h = h_in + i;
//        int w = w_in + j;
//        *temp_col = (h >= 0 && w >= 0 && h < height && w < width) ?
//            temp_img[i * width + j] : 0;
//        temp_col += height_col * width_col;
//      }
//    }
//  }
//}

template <typename Dtype>
void im2col_gpu(const Dtype* data_im, const int channels,
				const int height, const int width, const int ksize, const int pad,
				const int stride, Dtype* data_col)
{
	// We are going to launch channels * height_col * width_col kernels, each
	// kernel responsible for copying a single-channel grid.
	int height_col = (height + 2 * pad - ksize) / stride + 1;
	int width_col = (width + 2 * pad - ksize) / stride + 1;
	int num_kernels = channels * height_col * width_col;
	// NOLINT_NEXT_LINE(whitespace/operators)
	im2col_gpu_kernel<Dtype><<<CAFFE_GET_BLOCKS(num_kernels),
		CAFFE_CUDA_NUM_THREADS>>>(
		num_kernels, data_im, height, width, ksize, pad, stride, height_col,
		width_col, data_col);
	CUDA_POST_KERNEL_CHECK;
}


// Explicit instantiation
template void im2col_gpu<float>(const float* data_im, const int channels,
								const int height, const int width, const int ksize, const int pad,
								const int stride, float* data_col);
template void im2col_gpu<double>(const double* data_im, const int channels,
								 const int height, const int width, const int ksize, const int pad,
								 const int stride, double* data_col);


// Helper function for using CUDA to add vectors in parallel.
//const float* data_im // raw data,
//const int channels // image channels
//const int height //image height
//const int width // image width
//const int ksize // kernel size
//const int pad // pad size
//const int stride // stride size
//const int height_col // output column height
//const int width_col // output column width
//float* data_col // outpu data

cudaError_t im2colWithCuda(
	const float* data_im,
	const int batch_size,
	const int channels,
	const int height, const int width, const int ksize, const int pad,
	const int stride,
	float* data_col,
	const int num_kernels,
	float* data_kernel,
	float* data_ret)
{
	float *dev_image = 0;
	float *dev_col = 0;
	float *dev_kernel = 0;
	float *dev_ret = 0;
	cudaError_t cudaStatus;
	StopWatchInterface *timer = NULL;

	cublasHandle_t handle;

	cublasStatus_t ret;

	ret = cublasCreate(&handle);

	if (ret != CUBLAS_STATUS_SUCCESS)
	{
		printf("cublasCreate returned error code %d, line(%d)\n", ret, __LINE__);
		goto Error;
	}

	sdkCreateTimer(&timer);

	int height_col = (height + 2 * pad - ksize) / stride + 1;
	int width_col = (width + 2 * pad - ksize) / stride + 1;
		
	int K = ksize*ksize*channels;
	int M = num_kernels;
	int N = height_col*width_col;

	int image_size = height * width * channels;
	int images_size = image_size * batch_size;

	int kernels_size = M * K;
	int col_size = N*K;
	int result_size = M * N * batch_size;


	// col 
	checkCudaErrors(cudaMalloc((void**)&dev_col, N * K *batch_size * sizeof(float)));
	
	// image
	checkCudaErrors(cudaMalloc((void**)&dev_image, images_size* sizeof(float)));
	checkCudaErrors(cudaMemcpy(dev_image, data_im, images_size * sizeof(float), cudaMemcpyHostToDevice));
	
	// kernel
	checkCudaErrors(cudaMalloc((void**)&dev_kernel, kernels_size * sizeof(float)));
	checkCudaErrors(cudaMemcpy(dev_kernel, data_kernel, kernels_size * sizeof(float), cudaMemcpyHostToDevice));

	// result
	checkCudaErrors(cudaMalloc((void**)&dev_ret, result_size * sizeof(float)));


	const float alpha = 1.0f;
    const float beta  = 0.0f;

	sdkStartTimer(&timer);
	float* t_dev_image = dev_image;
	float* t_dev_col = dev_col;
	float* t_dev_kernel = dev_kernel;
	float* t_dev_ret = data_ret;
	for(int i = 0; i < batch_size; i++)
	{
		// Launch a kernel on the GPU with one thread for each element.
		im2col_gpu<float>(t_dev_image, channels, height, width, ksize, pad, stride, t_dev_col);


        //Perform warmup operation with cublas
		t_dev_image += image_size;
		t_dev_col += col_size;
		t_dev_ret += M*N;
	}

	// Check for any errors launching the kernel
	checkCudaErrors(cudaGetLastError());
	
	// cudaDeviceSynchronize waits for the kernel to finish, and returns
	// any errors encountered during the launch.
	cudaStatus = cudaDeviceSynchronize();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching im2col Kernel!\n", cudaStatus);
		goto Error;
	}

	sdkStopTimer(&timer);
	double elapsedTimeInMs = sdkGetTimerValue(&timer);
	printf("caffe is %fms\n", elapsedTimeInMs);

	// Copy output vector from GPU buffer to host memory.
	checkCudaErrors(cudaMemcpy(data_col, dev_col, N * K *batch_size* sizeof(float), cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(data_ret, dev_ret, result_size * sizeof(float), cudaMemcpyDeviceToHost));
	ret = cublasDestroy(handle);
	if (ret != CUBLAS_STATUS_SUCCESS)
	{
		printf("cublasDestroy returned error code %d, line(%d)\n", ret, __LINE__);
		goto Error;
	}
Error:

	cudaFree(dev_image);
	cudaFree(dev_col);
	cudaFree(dev_kernel);
	cudaFree(dev_ret);
	sdkDeleteTimer(&timer);


	return cudaStatus;
}