FROM php:8.3-apache-bookworm

ARG ITOP_VERSION=3.3.0-21411

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libpng-dev \
      libjpeg62-turbo-dev \
      libfreetype6-dev \
      libicu-dev \
      libzip-dev \
      libldap2-dev \
      libxml2-dev \
      libonig-dev \
      graphviz \
      unzip \
      default-mysql-client \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j2 \
      gd intl mysqli pdo_mysql soap zip mbstring ldap opcache \
 && pecl install apcu \
 && docker-php-ext-enable apcu \
 && rm -rf /var/lib/apt/lists/*

COPY docker/iTop-${ITOP_VERSION}.zip /tmp/itop.zip

RUN unzip -q /tmp/itop.zip 'web/*' -d /tmp/itop \
 && cp -a /tmp/itop/web/. /var/www/html/ \
 && mkdir -p \
      /var/www/html/conf \
      /var/www/html/data \
      /var/www/html/log \
      /var/www/html/env-production \
      /var/www/html/env-production-build \
      /var/www/html/env-test \
      /var/www/html/env-test-build \
 && chown -R www-data:www-data /var/www/html \
 && rm -rf /tmp/itop /tmp/itop.zip

COPY docker/config/itop.ini /usr/local/etc/php/conf.d/itop.ini
COPY docker/config/itop-apache.conf /etc/apache2/conf-available/itop.conf

RUN a2enmod rewrite headers \
 && a2enconf itop \
 && install -d -o www-data -g www-data -m 0700 /var/lib/php/sessions \
 && chmod 0644 \
      /usr/local/etc/php/conf.d/*.ini \
      /etc/apache2/conf-available/itop.conf

EXPOSE 80

# Elrehan Service Portal branding extension v0.2.1
COPY branding/elrehan-service-portal/ \
     /var/www/html/extensions/elrehan-service-portal/

RUN chown -R www-data:www-data \
      /var/www/html/extensions/elrehan-service-portal \
 && find /var/www/html/extensions/elrehan-service-portal \
      -type f -exec chmod 0644 {} \;
