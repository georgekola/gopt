#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <unistd.h>

// nvcc assumes that all header files are C++ files. Tell it
// that these are C header files
extern "C" {
#include "worker-master.h"
#include "util.h"
}

__global__ void
masterGpu(int *req, int *resp, int num_reqs)
{
	int i = blockDim.x * blockIdx.x + threadIdx.x;

	if (i < num_reqs) {
		resp[i] = 7;
	}
}

/**
 * wmq : the worker/master queue for all lcores. Non-NULL iff the lcore
 * 		 is an active worker.
 */
void master_gpu(volatile struct wm_queue *wmq, 
	int *h_reqs, int *d_reqs,						/**< Kernel inputs */
	int *h_resps, int *d_resps,			/**< Kernel outputs */
	int num_workers, int *worker_lcores)
{
	assert(num_workers != 0);
	assert(worker_lcores != NULL);
	assert(num_workers * WM_QUEUE_THRESH < WM_QUEUE_CAP);
	
	int i, err, iter = 0;
	long long total_req = 0;

	/** The GPU-buffer (h_reqs) start index for an lcore's packets 
	 *	during a kernel launch */
	int req_lo[WM_MAX_LCORE] = {0};

	/** Number of requests that we'll send to the GPU = nb_req.
	 *  We don't need to worry about nb_req overflowing the
	 *  capacity of h_reqs because it fits all WM_MAX_LCORE */
	int nb_req = 0;

	/** <  Value of the queue-head from an lcore during the last iteration*/
	long long prev_head[WM_MAX_LCORE] = {0}, new_head[WM_MAX_LCORE] = {0};
	
	int w_i, w_lid;		/**< A worker-iterator and the worker's lcore-id */
	volatile struct wm_queue *lc_wmq;	/**< Work queue of one worker */

	while(1) {

		/**< Copy all the requests supplied by workers into the 
		  * contiguous h_reqs buffer */
		for(w_i = 0; w_i < num_workers; w_i ++) {
			w_lid = worker_lcores[w_i];		// Don't use w_i after this
			lc_wmq = &wmq[w_lid];
			
			// Snapshot this worker queue's head
			new_head[w_lid] = lc_wmq->head;

			// Note the GPU-buffer extent for this lcore
			req_lo[w_lid] = nb_req;

			// Iterate over the new packets
			for(i = prev_head[w_lid]; i < new_head[w_lid]; i ++) {
				int q_i = i & WM_QUEUE_CAP_;	// Offset in this wrkr's queue
				int req = lc_wmq->reqs[q_i];

				h_reqs[nb_req] = req;			
				nb_req ++;
			}
		}

		if(nb_req == 0) {		// No new packets?
			continue;
		}

		iter ++;
		total_req += nb_req;
		if(iter == 10000) {
			red_printf("\tGPU master: average batch size = %lld\n",
				total_req / iter);
			iter = 0;
			total_req = 0;
		}

		/**< Copy requests to device */
		err = cudaMemcpy(d_reqs, h_reqs, nb_req * sizeof(int), 
			cudaMemcpyHostToDevice);
		CPE(err != cudaSuccess, "Failed to copy requests from host to device\n");

		/**< Kernel launch */
		int threadsPerBlock = 256;
		int blocksPerGrid = (nb_req + threadsPerBlock - 1) / threadsPerBlock;
	
		masterGpu<<<blocksPerGrid, threadsPerBlock>>>(d_reqs, d_resps, nb_req);
		err = cudaGetLastError();
		CPE(err != cudaSuccess, "Failed to launch masterGpu kernel\n");

		err = cudaMemcpy(h_resps, d_resps, nb_req * sizeof(int),
			cudaMemcpyDeviceToHost);
		CPE(err != cudaSuccess, "Failed to copy responses from device to host\n");

		/**< Copy the ports back to worker queues */
		for(w_i = 0; w_i < num_workers; w_i ++) {
			w_lid = worker_lcores[w_i];		// Don't use w_i after this

			lc_wmq = &wmq[w_lid];
			for(i = prev_head[w_lid]; i < new_head[w_lid]; i ++) {
	
				/** < Offset in this workers' queue and the GPU-buffer */
				int q_i = i & WM_QUEUE_CAP_;				
				int req_i = req_lo[w_lid] + (i - prev_head[w_lid]);
				lc_wmq->resps[q_i] = h_resps[req_i];
			}

			prev_head[w_lid] = new_head[w_lid];
		
			/** < Update tail for this worker */
			lc_wmq->tail = new_head[w_lid];
		}

		nb_req = 0;
	}
}

int main(int argc, char **argv)
{
	int c, i, err = cudaSuccess;
	int lcore_mask = -1;
	volatile struct wm_queue *wmq;

	/** < CUDA buffers */
	int *h_reqs, *d_reqs;
	int *h_resps, *d_resps;	

	/**< Get the worker lcore mask */
	while ((c = getopt (argc, argv, "c:")) != -1) {
		switch(c) {
			case 'c':
				printf("\tGPU master: Got lcore_mask = %s\n", optarg);
				// atoi() doesn't work for hex representation
				lcore_mask = strtol(optarg, NULL, 16);
				break;
			default:
				red_printf("\tGPU master: I need coremask. Exiting!\n");
				exit(-1);
		}
	}

	assert(lcore_mask != -1);
	red_printf("\tGPU master: got lcore_mask: %d\n", lcore_mask);

	/**< Allocate hugepages for the shared queues */
	red_printf("\tGPU master: creating worker-master shm queues\n");
	int wm_queue_bytes = M_2;
	while(wm_queue_bytes < WM_MAX_LCORE * sizeof(struct wm_queue)) {
		wm_queue_bytes += M_2;
	}
	printf("\t\tTotal size of wm_queues = %d hugepages\n", 
		wm_queue_bytes / M_2);
	wmq = (volatile struct wm_queue *) shm_alloc(WM_QUEUE_KEY, wm_queue_bytes);

	for(i = 0; i < WM_MAX_LCORE; i ++) {
		uint64_t c1 = (uint64_t) (uintptr_t) &wmq[i].head;
		uint64_t c2 = (uint64_t) (uintptr_t) &wmq[i].tail;
		uint64_t c3 = (uint64_t) (uintptr_t) &wmq[i].sent;

		// Ensure that all counters are in separate cachelines
		assert((c1 % 64 == 0) && (c2 % 64 == 0) && (c3 % 64 == 0));
	}

	red_printf("\tGPU master: creating worker-master shm queues done\n");

	/** < Allocate buffers for requests from all workers*/
	red_printf("\tGPU master: creating buffers for requests\n");
	int reqs_buf_size = WM_QUEUE_CAP * WM_MAX_LCORE * sizeof(int);
	err = cudaMallocHost((void **) &h_reqs, reqs_buf_size);
	err = cudaMalloc((void **) &d_reqs, reqs_buf_size);
	CPE(err != cudaSuccess, "Failed to cudaMalloc req buffer\n");

	/** < Allocate buffers for responses for all workers */
	red_printf("\tGPU master: creating buffers for responses\n");
	int resps_buf_size = WM_QUEUE_CAP * WM_MAX_LCORE * sizeof(int);
	err = cudaMallocHost((void **) &h_resps, resps_buf_size);
	err = cudaMalloc((void **) &d_resps, resps_buf_size);
	CPE(err != cudaSuccess, "Failed to cudaMalloc resp buffers\n");

	int num_workers = bitcount(lcore_mask);
	int *worker_lcores = get_active_bits(lcore_mask);
	
	/** < Launch the GPU master */
	red_printf("\tGPU master: launching GPU code\n");
	master_gpu(wmq, 
		h_reqs, d_reqs, 
		h_resps, d_resps, 
		num_workers, worker_lcores);
	
}
