#include "common.h"
#include <assert.h>
#include <sys/ipc.h>
#include <sys/shm.h>

cudaStream_t myStream;

__global__ void
vectorAdd(int *pkts, int num_pkts)
{
	int i = blockDim.x * blockIdx.x + threadIdx.x;

	if (i < num_pkts) {
		pkts[i] = (pkts[i] + 1) * pkts[i];
	}
}

double cpu_run(int *pkts, int num_pkts)
{
	int i;
	struct timespec start, end;
	clock_gettime(CLOCK_REALTIME, &start);

	for(i = 0; i < num_pkts; i += 1) {
		pkts[i] = (pkts[i] + 1) * pkts[i];
	}

	clock_gettime(CLOCK_REALTIME, &end);
	double time = (double) (end.tv_nsec - start.tv_nsec) / 1000000000 + 
		(end.tv_sec - start.tv_sec);
	return time;
}

#if INCLUDE_COPY_TIME == 1
/**< Include copy overhead in measurement */
double gpu_run(int *h_pkts, int *d_pkts, int num_pkts)
{
	struct timespec start, end;
	int err = cudaSuccess;

	clock_gettime(CLOCK_REALTIME, &start);

	/**< Copy packets to device */
	err = cudaMemcpyAsync(d_pkts, h_pkts, num_pkts * sizeof(int), 
		cudaMemcpyHostToDevice, myStream);
	CPE(err != cudaSuccess, "Failed to copy to device memory\n", -1);

	/**< Kernel launch */
	int threadsPerBlock = 256;
	int blocksPerGrid = (num_pkts + threadsPerBlock - 1) / threadsPerBlock;

	vectorAdd<<<blocksPerGrid, threadsPerBlock, 0, myStream>>>(d_pkts, 
		num_pkts);
	err = cudaGetLastError();
	CPE(err != cudaSuccess, "Failed to launch vectorAdd kernel\n", -1);

	/**< Copy back the results */
	err = cudaMemcpyAsync(h_pkts, d_pkts, num_pkts * sizeof(int),
		cudaMemcpyDeviceToHost, myStream);
	CPE(err != cudaSuccess, "Failed to copy C from device to host\n", -1);

	/**< Wait for all stream ops to complete */
	cudaStreamSynchronize(myStream);

	clock_gettime(CLOCK_REALTIME, &end);
	double time = (double) (end.tv_nsec - start.tv_nsec) / 1000000000 + 
		(end.tv_sec - start.tv_sec);

	return time;
}

#else
/**< Don't include copy overhead in measurement */
double gpu_run(int *h_pkts, int *d_pkts, int num_pkts)
{
	struct timespec start, end;
	int err = cudaSuccess;


	/**< Copy packets to device */
	err = cudaMemcpy(d_pkts, h_pkts, num_pkts * sizeof(int), 
		cudaMemcpyHostToDevice);
	CPE(err != cudaSuccess, "Failed to copy to device memory\n", -1);

	/**< Memcpy has completed: start timer */
	clock_gettime(CLOCK_REALTIME, &start);

	/**< Kernel launch */
	int threadsPerBlock = 256;
	int blocksPerGrid = (num_pkts + threadsPerBlock - 1) / threadsPerBlock;

	vectorAdd<<<blocksPerGrid, threadsPerBlock>>>(d_pkts, num_pkts);
	err = cudaGetLastError();
	CPE(err != cudaSuccess, "Failed to launch vectorAdd kernel\n", -1);
	cudaDeviceSynchronize();

	/**< Kernel execution finished: stop timer */
	clock_gettime(CLOCK_REALTIME, &end);

	/**< Copy back the results */
	err = cudaMemcpy(h_pkts, d_pkts, num_pkts * sizeof(int),
		cudaMemcpyDeviceToHost);
	CPE(err != cudaSuccess, "Failed to copy C from device to host\n", -1);

	double time = (double) (end.tv_nsec - start.tv_nsec) / 1000000000 + 
		(end.tv_sec - start.tv_sec);

	return time;
}

#endif

int main(int argc, char *argv[])
{
	int err = cudaSuccess;
	int i;
	int *h_pkts_cpu;
	/** <Separate packet buffer to compare GPU's result with the CPU's */
	int *h_pkts_gpu, *d_pkts_gpu;

	srand(time(NULL));

	printDeviceProperties();

	/** <Initialize a cudaStream for async calls */
	err = cudaStreamCreate(&myStream);
	CPE(err != cudaSuccess, "Failed to create cudaStream\n", -1);


	/** <Initialize the packet arrays for CPU and GPU code */
	h_pkts_cpu =  (int *) malloc(MAX_PKTS * sizeof(int));

	/** <The host packet-array for GPU code should be pinned */
	err = cudaMallocHost((void **) &h_pkts_gpu, MAX_PKTS * sizeof(int));
	err = cudaMalloc((void **) &d_pkts_gpu, MAX_PKTS * sizeof(int));

	/** <Test for different batch sizes */
	assert(MAX_PKTS % 8 == 0);
	for(int num_pkts = 8; num_pkts < MAX_PKTS; num_pkts += 8) {

		double cpu_time = 0, gpu_time = 0;

		/** <Initialize packets */
		for(i = 0; i < num_pkts; i ++) {
			h_pkts_cpu[i] = rand();
			h_pkts_gpu[i] = h_pkts_cpu[i];
		}
	
		/** Perform several measurements for averaging */
		for(i = 0; i < ITERS; i ++) {
			cpu_time += cpu_run(h_pkts_cpu, num_pkts);
			gpu_time += gpu_run(h_pkts_gpu, d_pkts_gpu, num_pkts);
		}
		
		cpu_time = cpu_time / ITERS;
		gpu_time = gpu_time / ITERS;
	
		/** <Verify that the result vector is correct */
		for(int i = 0; i < num_pkts; i ++) {
			if (h_pkts_cpu[i] != h_pkts_gpu[i]) {
				fprintf(stderr, "Result verification failed at element %d!\n", i);
				fprintf(stderr, "CPU %d, GPU %d\n", h_pkts_cpu[i], h_pkts_gpu[i]);
				exit(-1);
			}
		}
	
		printf("Test PASSED for num_pkts = %d\n", num_pkts);
		printf("CPU: time per packet %.2f ns\n", 
			(cpu_time * 1000000000) / num_pkts);
		printf("GPU: time per packet %.2f ns\n", 
			(gpu_time * 1000000000) / num_pkts);

		/** <Emit the results to stderr. Use only space for delimiting */
		fprintf(stderr, "Batch size  %d CPU %f GPU %f CPU/GPU %f\n",
			num_pkts, cpu_time, gpu_time, cpu_time / gpu_time);

		printf("\n");
	
	}

	// Free device memory
	cudaFree(d_pkts_gpu);

	// Free host memory
	free(h_pkts_cpu);
	cudaFreeHost(h_pkts_gpu);

	// Reset the device and exit
	err = cudaDeviceReset();
	CPE(err != cudaSuccess, "Failed to de-initialize the device\n", -1);

	printf("Done\n");
	return 0;
}

