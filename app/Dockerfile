# Base imaj Docker Hub'dan. GitHub Actions runner'ları Docker Hub'dan sorunsuz çekiyor.
# (public.ecr.aws, paylaşımlı runner IP'lerinde anonim limit yüzünden 429 veriyordu.)
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
