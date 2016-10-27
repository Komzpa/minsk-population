-- узнаем, какие вообще бывают здания в нашем наборе данных и выпишем те, в которых могут жить люди
select
    building,
    count(*)
from planet_osm_polygon
group by 1
order by 2 desc;

-- создадим таблицу, в которой оставим только жилые дома, площадь фундамента и этажность
drop table if exists where_people_live;
create table where_people_live as (
    select
        way                                                                         as geom,
        ST_Area(ST_Transform(way, 4326) :: geography) :: float                      as area,
        nullif(regexp_replace(tags -> 'building:levels', '\D+.*', ''), '') :: float as levels,
        null :: float                                                               as population,
        null :: float                                                               as population_man,
        null :: float                                                               as population_woman
    from planet_osm_polygon
    where building in ('yes', 'residential', 'house', 'apartments', 'detached')
          and sport is null -- уберём Минск-Арену
          and shop is null -- уберём торговые центры
          and railway is null -- уберём депо метрополитена
          and amenity is null -- уберём автобусные депо, кинотеатры, детские сады, школы
          and leisure is null -- уберём стадионы
          and name is null -- уберём всё именованное, оно скорее всего административное или теплицы
);

create index on where_people_live using gist (geom);

-- уберём всё, что попало в нежилую зону
delete from where_people_live b
using planet_osm_polygon p
where
    ST_Intersects(p.way, b.geom)
    and (p.landuse in ('industrial', 'garages', 'commercial', 'retail', 'military')
         or p.amenity in ('kindergarten', 'school', 'university')
    );

-- у многих зданий нет этажности

-- предположим, что в кварталах городской застройки - пятиэтажки, а в частном секторе - одноэтажные дома
update where_people_live b
set
    levels =
    case when (p.tags -> 'residential') = 'rural'
        then 1
    when (p.tags -> 'residential') = 'urban'
        then 5
    end
from planet_osm_polygon p
where
    ST_Intersects(p.way, b.geom)
    and p.tags ? 'residential';

-- поставим отсутствующие этажности по популярной этажности в окрестности в 1000 метров, если такая есть
update where_people_live b
set
    levels = (
        select mode()
        within group (order by levels)
        from where_people_live w
        where
            w.levels is not null
            and ST_DWithin(b.geom, w.geom, 1000)
    )
where levels is null;

-- всё остальное - поставим по соседнему дому
update where_people_live b
set
    levels = (
        select levels
        from where_people_live w
        where w.levels is not null
        order by b.geom <-> w.geom
        limit 1
    )
where levels is null;

-- расставляем население простой пропорцией метража
with population_areas as (
    select
        population :: float,
        (tags -> 'population:woman') :: float as population_woman,
        (tags -> 'population:man') :: float   as population_man,
        way                                   as geom,
        (
            select sum(area * levels)
            from where_people_live w
            where ST_Intersects(w.geom, p.way)
        )                                     as total_m2
    from planet_osm_polygon p
    where population is not null
          and admin_level = '9'
)
update where_people_live w
set
    population       = p.population * w.area * w.levels / p.total_m2,
    population_man   = p.population_man * w.area * w.levels / p.total_m2,
    population_woman = p.population_woman * w.area * w.levels / p.total_m2
from population_areas p
where ST_Intersects(p.geom, w.geom);

-- удалим всё, на что у нас нет данных по населению
delete from where_people_live
where population is null;

-- проверяем, что имеем право округлить до целых население каждого дома:
select
    sum(round(population))                                          as rounded_total_population,
    sum(population)                                                 as total_population,
    abs(sum(round(population)) - sum(population))                   as population_error,
    abs(sum(round(population)) - sum(population)) / sum(population) as relative_population_error
from where_people_live;

-- ошибка в масштабе города всего в сотню человек - имеем право округлить
update where_people_live
set
    population       = round(population),
    population_woman = round(population_woman),
    population_man   = round(population_man);

-- уберём все дома, в которых население обнулилось
delete from where_people_live
where population = 0;

-- узнаем, какие вообще бывают заведения
select
    amenity,
    count(*)
from planet_osm_point
group by 1
order by 2 desc;

-- а давайте забудем про дома и просто посмотрим, где люди живут
drop table if exists population_aggregate;
create table population_aggregate as (
    select
        ST_Expand(ST_SnapToGrid(ST_Centroid(geom), 1000), 500) as geom,
        sum(population)                                        as population,
        null :: bigint                                         as cafes,
        null :: float                                          as cafes_per_thousand
    from where_people_live w
    where population > 200
    group by 1
);

-- а сколько ж у них кафешек-то тогда под домом?
update population_aggregate c
set
    cafes = (
        select count(*)
        from planet_osm_point
        where
            amenity in ('cafe', 'restaurant', 'fast_food', 'bar')
            and ST_Intersects(way, geom)
    );

update population_aggregate
set
    cafes_per_thousand = cafes * 1000 / population;