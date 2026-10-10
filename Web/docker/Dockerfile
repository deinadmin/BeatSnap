FROM php:8.3-apache

RUN a2enmod rewrite headers expires \
    && sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf \
    && mkdir -p /var/beatsnap-storage \
    && chown www-data:www-data /var/beatsnap-storage

COPY php-dev.ini /usr/local/etc/php/conf.d/zz-beatsnap-dev.ini
