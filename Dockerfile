# Redis-less test image — extends the custom Vyogo SNE all-in-one image with
# patched Frappe cache/job files and a modified run script that skips Redis.
FROM docker.io/vyogo/erpnext:sne-version-16

USER root

COPY patched/frappe/utils/redis_wrapper.py \
     /home/frappe/frappe-bench/apps/frappe/frappe/utils/redis_wrapper.py
COPY patched/frappe/utils/background_jobs.py \
     /home/frappe/frappe-bench/apps/frappe/frappe/utils/background_jobs.py
COPY patched/frappe/utils/scheduler.py \
     /home/frappe/frappe-bench/apps/frappe/frappe/utils/scheduler.py
COPY patched/frappe/realtime.py \
     /home/frappe/frappe-bench/apps/frappe/frappe/realtime.py
COPY patched/realtime/index.js \
     /home/frappe/frappe-bench/apps/frappe/realtime/index.js
COPY patched/realtime/middlewares/authenticate.js \
     /home/frappe/frappe-bench/apps/frappe/realtime/middlewares/authenticate.js

COPY run-no-redis.sh /usr/libexec/s2i/run
RUN chmod +x /usr/libexec/s2i/run && \
    chown 1001:0 /usr/libexec/s2i/run \
                 /home/frappe/frappe-bench/apps/frappe/frappe/utils/redis_wrapper.py \
                 /home/frappe/frappe-bench/apps/frappe/frappe/utils/background_jobs.py \
                 /home/frappe/frappe-bench/apps/frappe/frappe/utils/scheduler.py \
                 /home/frappe/frappe-bench/apps/frappe/frappe/realtime.py \
                 /home/frappe/frappe-bench/apps/frappe/realtime/index.js \
                 /home/frappe/frappe-bench/apps/frappe/realtime/middlewares/authenticate.js

USER 1001
