# Base imaj Docker Hub'dan. GitHub Actions runner'ları Docker Hub'dan sorunsuz çekiyor.
# (public.ecr.aws, paylaşımlı runner IP'lerinde anonim limit yüzünden 429 veriyordu.)
# nginx-unprivileged: süreçler root yerine "nginx" (uid 101) kullanıcısıyla çalışır ve
# yetki gerektirmeyen 8080 portunu dinler. Sunucuda 80 → 8080 eşleniyor (SSM dokümanı).
FROM nginxinc/nginx-unprivileged:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080

# Docker container'ın sağlığını izler ("docker ps" STATUS sütununda healthy/unhealthy).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1
