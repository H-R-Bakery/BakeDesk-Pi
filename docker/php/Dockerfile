# syntax=docker/dockerfile:1.7

FROM php:8.4-fpm-bookworm AS build

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_HOME=/tmp/composer

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        libcurl4-openssl-dev \
        libicu-dev \
        libonig-dev \
        libpq-dev \
        libxml2-dev \
        libzip-dev \
        unzip \
        $PHPIZE_DEPS \
    && docker-php-ext-install -j"$(nproc)" \
        curl \
        intl \
        mbstring \
        opcache \
        pcntl \
        pdo_pgsql \
        xml \
        zip \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && rm -rf /var/lib/apt/lists/* /tmp/pear

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

# Copy dependency manifests first so ordinary application edits reuse the
# Composer dependency layer.
COPY app/composer.json app/composer.lock ./
RUN composer install \
        --no-dev \
        --no-interaction \
        --no-progress \
        --prefer-dist \
        --classmap-authoritative \
        --no-scripts

COPY app/ ./
RUN composer dump-autoload --no-dev --no-interaction --classmap-authoritative

# These values exist only while building the image; Compose supplies the real
# production environment at runtime.
ENV APP_ENV=prod \
    APP_DEBUG=0 \
    APP_SECRET=bakedesk-image-build-secret \
    DEFAULT_URI="http://bakedesk.local" \
    BAKERY_TIMEZONE="America/Indiana/Indianapolis" \
    BAKERY_BRAND_NAME="H&R Bakery" \
    BAKEDESK_BRAND_NAME=BakeDesk \
    BAKERY_LOGO_ASSET="Images/HRBakeryLogo.svg" \
    BAKERY_PRINT_LOGO_PATH="assets/Images/HRBakeryLogo_bw.svg" \
    GOTENBERG_BASE_URL="http://gotenberg:8833" \
    DATABASE_URL="postgresql://baker:build-only@database:5432/bakery?serverVersion=18" \
    MESSENGER_TRANSPORT_DSN="redis://valkey:6379/messages" \
    MERCURE_URL="http://mercure/.well-known/mercure" \
    MERCURE_PUBLIC_URL="http://bakedesk.local/.well-known/mercure" \
    MERCURE_JWT_SECRET=bakedesk-image-build-secret

RUN touch .env \
    && mkdir -p var/cache var/log var/storage/default var/storage/documents \
    && php bin/console cache:clear --no-warmup \
    && php bin/console assets:install public \
    && php bin/console importmap:install --no-interaction \
    && php bin/console asset-map:compile --no-interaction \
    && rm -f .env

FROM php:8.4-fpm-bookworm AS production

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libcurl4 \
        libicu72 \
        libonig5 \
        libpq5 \
        libxml2 \
        libzip4 \
    && rm -rf /var/lib/apt/lists/*

# The build and runtime images use the same PHP ABI and base distribution.
COPY --from=build /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=build /usr/local/etc/php/conf.d/docker-php-ext-*.ini /usr/local/etc/php/conf.d/
COPY deploy/docker/php/php.ini /usr/local/etc/php/conf.d/zz-bakedesk.ini
COPY deploy/docker/php/www.conf /usr/local/etc/php-fpm.d/zz-bakedesk.conf

WORKDIR /var/www/html
RUN rm -f /usr/local/etc/php-fpm.d/www.conf
COPY --from=build --chown=www-data:www-data /var/www/html /var/www/html

RUN mkdir -p var/cache var/log var/storage/default var/storage/documents \
    && chown -R www-data:www-data var

USER www-data
EXPOSE 9000
CMD ["php-fpm", "--nodaemonize"]
