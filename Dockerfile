FROM ruby:3.3-alpine

# ติดตาม build-base กรณีที่ gem บางตัวต้อง compile native extensions
RUN apk add --no-cache build-base iproute2 \
    git \
    openssh-client \
    ca-certificates \
    && gem install sinatra rackup puma --no-document

WORKDIR /app

COPY git-sync.rb .

# สร้าง directory สำหรับเก็บ state และกำหนดสิทธิ์
RUN mkdir -p /data

# เปิด port ตามที่ set ไว้ในโค้ด (8080)
EXPOSE 8080

CMD ["ruby", "git-sync.rb"]
