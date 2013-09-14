#!/bin/bash

function print_info {
    echo -n -e '\e[1;36m'
    echo -n $1
    echo -e '\e[0m'
}

function print_warn {
    echo -n -e '\e[1;33m'
    echo -n $1
    echo -e '\e[0m'
}

function install_updates {
  apt-get -q -y update
    apt-get -q -y upgrade
}

function check_install {
    if [ -z "`which "$1" 2>/dev/null`" ]
    then
        executable=$1
        shift
        while [ -n "$1" ]
        do
            DEBIAN_FRONTEND=noninteractive apt-get -q -y install "$1"
            print_info "$1 installed for $executable"
            shift
        done
    else
        print_warn "$2 already installed"
    fi
}

function check_sanity {
    # Do some sanity checking.
    if [ $(/usr/bin/id -u) != "0" ]
    then
        die 'Must be run by root user'
    fi

    if [ ! -f /etc/debian_version ]
    then
        die "Distribution is not supported"
    fi
}

function get_domain_name() {
    # Getting rid of the lowest part.
    domain=${1%.*}
    lowest=`expr "$domain" : '.*\.\([a-z][a-z]*\)'`
    case "$lowest" in
    com|net|org|gov|edu|co)
        domain=${domain%.*}
        ;;
    esac
    lowest=`expr "$domain" : '.*\.\([a-z][a-z]*\)'`
    [ -z "$lowest" ] && echo "$domain" || echo "$lowest"
}

function get_password() {
    # Check whether our local salt is present.
    SALT=/var/lib/radom_salt
    if [ ! -f "$SALT" ]
    then
        head -c 512 /dev/urandom > "$SALT"
        chmod 400 "$SALT"
    fi
    password=`(cat "$SALT"; echo $1) | md5sum | base64`
    echo ${password:0:13}
}

function remove_apache {
	apt-get -y remove apache2*
	}

function install_ufw {
	check_install wget wget
	apt-get install ufw
	cd /etc/default/
	rm -f ufw
	wget --no-check-certificate https://raw.github.com/DustinHyle/fshosted/master/ufw
	ufw allow ssh
	ufw allow http
	ufw logging off
	ufw enable
}

function install_mysql {
    # Install the MySQL packages
    check_install mysqld mysql-server
    check_install mysql mysql-client
	
	invoke-rc.d mysql start
	
	# Generating a new password for the root user.
    passwd=`get_password root@mysql`
    mysqladmin password "$passwd"
    cat > ~/.my.cnf <<END
[client]
user = root
password = $passwd
END
    chmod 600 ~/.my.cnf
}

function install_php {
	check_install wget wget
	apt-get -y install php5-fpm php-pear php5-common php5-mysql php-apc php5-gd
	
	cat > /etc/php5/fpm/php.ini <<END
	[apc]
	apc.write_lock = 1
	apc.slam_defense = 0
END

	cd /etc/php5/fpm/pool.d/
	rm -f www.conf
	wget --no-check-certificate https://raw.github.com/DustinHyle/fshosted/master/www.conf
}

function install_nginx {
	check_install wget wget
	cd /tmp/
	wget http://nginx.org/keys/nginx_signing.key
	apt-key add /tmp/nginx_signing.key
	
	echo "deb http://nginx.org/packages/ubuntu/ lucid nginx" >> /etc/apt/sources.list
	echo "deb-src http://nginx.org/packages/ubuntu/ lucid nginx" >> /etc/apt/sources.list
	
	apt-get update
	apt-get -y install nginx
	
	cd /etc/nginx/
	rm -f nginx.conf
	wget --no-check-certificate https://raw.github.com/DustinHyle/fshosted/master/nginx.conf
	
	cd /etc/nginx/conf.d/
	wget --no-check-certificate https://raw.github.com/DustinHyle/fshosted/master/drop
	rm -f default.conf
	
	service nginx restart
	service php5-fpm restart
}

function install_varnish {
	check_install wget wget
	apt-get -y install varnish
	
	cd /etc/varnish/
	rm -f default.vcl
	wget --no-check-certificate https://raw.github.com/DustinHyle/fshosted/master/default.vcl
	
	cd /etc/default/
	rm -f varnish
	wget --no-check-certificate https://raw.github.com/DustinHyle/fshosted/master/varnish
}

function install_wordpress {
    check_install wget wget
    if [ -z "$1" ]
    then
        die "Usage: `basename $0` wordpress <hostname>"
    fi

    # Downloading the WordPress' latest and greatest distribution.
    mkdir /tmp/wordpress.$$
    wget -O - http://wordpress.org/latest.tar.gz | \
        tar zxf - -C /tmp/wordpress.$$
    mkdir "/var/www/$1"
    mv /tmp/wordpress.$$/wordpress "/var/www/$1"
    rm -rf /tmp/wordpress.$$
    chown nginx:nginx -R "/var/www/$1"

    # Setting up the MySQL database
    dbname=`echo $1 | tr . _`
    userid=`get_domain_name $1`
    # MySQL userid cannot be more than 15 characters long
	userid="${userid:0:15}"
    passwd=`get_password "$userid@mysql"`
    cp "/var/www/$1/wp-config-sample.php" "/var/www/$1/wp-config.php"
    sed -i "s/database_name_here/$dbname/; s/username_here/$userid/; s/password_here/$passwd/" \
        "/var/www/$1/wp-config.php"
    mysqladmin create "$dbname"
    echo "GRANT ALL PRIVILEGES ON \`$dbname\`.* TO \`$userid\`@localhost IDENTIFIED BY '$passwd';" | \
        mysql

	cat > "/etc/nginx/conf.d/$1.conf" <<END
server {
    ## Your website name goes here.
	server_name $1 www.$1;
    ## Your only path reference.
    root /var/www/$1/;
    listen 8080;
    ## This should be in your http block and if it is, it's not needed here.
    index index.html index.htm index.php;

    include conf.d/drop;

        location / {
                # This is cool because no php is touched for static content
			try_files \$uri \$uri/ /index.php?q=\$uri&\$args;
        }

        location ~ \.php$ {
            fastcgi_buffers 8 256k;
            fastcgi_buffer_size 128k;
            fastcgi_intercept_errors on;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_pass unix:/dev/shm/php-fpm-www.sock;

        }



}
END

service nginx restart
service varnish restart	

}

########################################################################
# START OF PROGRAM
########################################################################
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

check_sanity
case "$1" in
updates)
	install_updates
	;;
apache)
	remove_apache
	;;
ufw)
    install_ufw
    ;;
mysql)
    install_mysql
    ;;
php)
    install_php
    ;;
nginx)
    install_nginx
    ;;
varnish)
    install_varnish
    ;;
wordpress)
    install_wordpress $2
    ;;
*)
    echo 'Usage:' `basename $0` '[option]'
    echo 'Available option:'
    for option in apache updates ufw mysql php nginx varnish wordpress
    do
        echo '  -' $option
    done
    ;;
esac
