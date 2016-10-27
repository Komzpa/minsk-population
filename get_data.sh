#!/usr/bin/env bash
wget http://data.gis-lab.info/osm_dump/dump/latest/BY.osm.pbf
osmupdate -v -b=27.3552344,53.7841053,28.1260829,53.9745307 --drop-version --drop-author BY.osm.pbf minsk.osm.pbf
osm2pgsql data/minsk.osm.pbf -U gis -d gis -s -k -G