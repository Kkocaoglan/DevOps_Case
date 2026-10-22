# Docker Hub yerine AWS'nin public ECR aynası: CodeBuild'in paylaşılan IP'leri
# Docker Hub'ın anonim indirme limitine (429 toomanyrequests) takılabiliyor.
FROM public.ecr.aws/nginx/nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
