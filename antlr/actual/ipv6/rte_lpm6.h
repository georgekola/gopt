/*-
 *   BSD LICENSE
 * 
 *   Copyright(c) 2010-2013 Intel Corporation. All rights reserved.
 *   All rights reserved.
 * 
 *   Redistribution and use in source and binary forms, with or without
 *   modification, are permitted provided that the following conditions
 *   are met:
 * 
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in
 *       the documentation and/or other materials provided with the
 *       distribution.
 *     * Neither the name of Intel Corporation nor the names of its
 *       contributors may be used to endorse or promote products derived
 *       from this software without specific prior written permission.
 * 
 *   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 *   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 *   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 *   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 *   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 *   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 *   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 *   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 *   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 *   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 *   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#define RTE_LPM6_MAX_DEPTH               128
#define RTE_LPM6_IPV6_ADDR_SIZE           16
/** Max number of characters in LPM name. */
#define RTE_LPM6_NAMESIZE                 32

/**< Added to avoid DPDK dependencies */
#define CACHE_LINE_SIZE 64
#define __rte_cache_aligned __attribute__((__aligned__(CACHE_LINE_SIZE)))

#define RTE_LPM6_SHM_KEY 1

/** LPM structure. */
struct rte_lpm6;

/** LPM configuration structure. */
struct rte_lpm6_config {
	uint32_t max_rules;      /**< Max number of rules. */
	uint32_t number_tbl8s;   /**< Number of tbl8s to allocate. */
	int flags;               /**< This field is currently unused. */
};

/**< Create an LPM object */
struct rte_lpm6 *rte_lpm6_create(int socket_id,
	const struct rte_lpm6_config *config);

/**< Free an LPM object */
void rte_lpm6_free(struct rte_lpm6 *lpm);

/**< Add a rule to the LPM table
  *  Return: 0 on success, negative value otherwise */
int rte_lpm6_add(struct rte_lpm6 *lpm,
	uint8_t *ip, uint8_t depth, uint8_t next_hop);

/**< Delete a rule from the LPM table */
int rte_lpm6_delete(struct rte_lpm6 *lpm, uint8_t *ip, uint8_t depth);

/**< Delete a rule from the LPM table */
int rte_lpm6_delete_bulk_func(struct rte_lpm6 *lpm,
	uint8_t ips[][RTE_LPM6_IPV6_ADDR_SIZE], uint8_t *depths, unsigned n);

/**< Delete all rules from the LPM table */
void rte_lpm6_delete_all(struct rte_lpm6 *lpm);

/**< Lookup an IP into the LPM table.
  *  Return: -EINVAL for incorrect arguments, otherwise 0 */
int rte_lpm6_lookup(const struct rte_lpm6 *lpm,
	uint8_t *ip, uint8_t *next_hop);

/**< Lookup multiple IP addresses in an LPM table.
  *  Return: -EINVAL for incorrect arguments, otherwise 0 */
int rte_lpm6_lookup_bulk_func(const struct rte_lpm6 *lpm,
	uint8_t ips[][RTE_LPM6_IPV6_ADDR_SIZE], int16_t *next_hops, unsigned n);

void rte_lpm6_lookup_nogoto(const struct rte_lpm6 *lpm,
	uint8_t ips[][RTE_LPM6_IPV6_ADDR_SIZE], int16_t *next_hops, unsigned n);

void rte_lpm6_lookup_goto(const struct rte_lpm6 *lpm,
	uint8_t ips[][RTE_LPM6_IPV6_ADDR_SIZE], int16_t *next_hops, unsigned n);

void rte_lpm6_lookup_handopt(const struct rte_lpm6 *lpm,
	uint8_t ips[][RTE_LPM6_IPV6_ADDR_SIZE], int16_t *next_hops, unsigned n);

void *hrd_malloc_socket(int shm_key, int size, int socket_id);
