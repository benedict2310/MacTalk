#include <pthread.h>
#include <stdatomic.h>

static atomic_int completed;

static void *worker(void *context) {
    (void)context;
    atomic_fetch_add_explicit(&completed, 1, memory_order_relaxed);
    return NULL;
}

int main(void) {
    pthread_t threads[2];
    for (int index = 0; index < 2; ++index) {
        if (pthread_create(&threads[index], NULL, worker, NULL) != 0) return 2;
    }
    for (int index = 0; index < 2; ++index) {
        if (pthread_join(threads[index], NULL) != 0) return 3;
    }
    return atomic_load_explicit(&completed, memory_order_relaxed) == 2 ? 0 : 4;
}
