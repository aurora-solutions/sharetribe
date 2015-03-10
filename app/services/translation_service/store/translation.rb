module TranslationService::Store::Translation

  CommunityTranslationModel = ::CommunityTranslation

  Translation = EntityUtils.define_builder(
    [:translation_key, :mandatory, :string],
    [:locale, :mandatory, :string],
    [:translation])


  module_function

  # Create translations
  # Format for translation_groups:
  # [ { translation_key: nil // optional key - if defined it will override previous translations
  #   , translations:
  #     [ { locale: "en-US"
  #       , translation: "Welcome"
  #       }
  #     , { locale: "fi-FI"
  #       , translation: "Tervetuloa"
  #       }
  #     ]
  #   }
  # ]
  def create(community_id:, translation_groups: [])

    translation_groups
      .map { |group|
        enforced_key = group[:translation_key]
        key = Maybe(enforced_key).or_else(gen_translation_uuid(community_id))

        translations = group[:translations]
          .map { |translation|

            translation_hash = {
              community_id: community_id,
              translation_key: key,
              locale: translation[:locale],
              translation: translation[:translation],
              is_key_enforced: enforced_key.present?
            }
            save_translation(translation_hash)
          }

        { translation_key: key,
          translations: translations
        }
      }
  end

  # Get translations
  # Format for params:
  # {community_id: 1, translation_keys: ["aa", "bb", "cc"], locales: ["en", "fi-FI", "sv-SE"], fallback_locale: "en"}
  def get(community_id:, translation_keys: [], locales: [], fallback_locale:nil)

    translations = Maybe(CommunityTranslationModel
        .where(get_search_hash(community_id, translation_keys, locales))
        .order("translation_key ASC")
      )
      .map { |models|
        from_model_array(models)
      }
      .or_else([])

    # add missing values if we know what values are expected
    if translation_keys.present? && locales.present?
      fill_in_delta(translations, translation_keys, locales, fallback_locale)
    else
      translations
    end

  end

  # Delete translations
  # Format for params:
  # {community_id: 1, translation_keys: ["aa", "bb", "cc"]}
  def delete(community_id:, translation_keys: [])
    Maybe(CommunityTranslationModel
        .where(community_id: community_id, translation_key: translation_keys)
      )
      .map { |models|
        models.map { |model|
          hash = from_model(model)
          model.destroy
          hash
        }
      }
      .or_else([])
  end


  # Privates

  def gen_translation_uuid(community_id)
    SecureRandom.uuid
  end

  def create_translation(options)
    options.assert_valid_keys(:community_id, :translation_key, :locale, :translation)
    from_model(CommunityTranslationModel.create!(options))
  end

  def update_translation(options)
    options.assert_valid_keys(:id, :translation)
    from_model(CommunityTranslationModel.update(options[:id], options.slice(:translation)))
  end

  def save_translation(options)
    options.assert_valid_keys(:community_id, :translation_key, :locale, :translation, :is_key_enforced)

    existing_translation = CommunityTranslationModel
      .where(options.slice(:community_id, :translation_key, :locale))
      .first

    if options[:is_key_enforced] && existing_translation
      update_translation(id: existing_translation.id, translation: options[:translation])
    else
      create_translation(options.slice(:community_id, :translation_key, :locale, :translation))
    end

  end

  def get_search_hash(community_id, translation_keys, locales)
    search_hash = { community_id: community_id }

    if translation_keys.present? && translation_keys.kind_of?(Array)
      search_hash.merge!(translation_key: translation_keys)
    end

    if locales.present? && locales.kind_of?(Array)
      search_hash.merge!(locale: locales)
    end
    search_hash
  end

  # if translation_hash does not include all combinations, add them
  def fill_in_delta(translations_hash, translation_keys, locales, fallback_locale)

    results = []
    translation_keys.each { |key|
      locales.each { |locale|

        results.push(
          Maybe(
            translations_hash.find { |t|
              t[:translation_key] == key && t[:locale] == locale && !t[:translation].empty?
            }
          )
          .or_else(create_delta_result(translations_hash, key, locale, fallback_locale))
        )

      }
    }
    results
  end

  def create_delta_result(translations_hash, translation_key, locale, fallback_locale)
    translations_with_key = translations_hash.select { |t|
      t[:translation_key] == translation_key && t[:translation].present?
    }

    fallback = Maybe(
      translations_with_key.find { |t|
        if fallback_locale.present? then t[:locale] == fallback_locale else false end;
      })
      .or_else(nil)

    use_fallback = fallback_locale.present? && fallback.present?
    Translation.call({
        translation_key: translation_key,
        locale: use_fallback ? fallback[:locale] : locale,
        translation: use_fallback ? fallback[:translation] : nil
      }).merge(error_message(translations_with_key.present?, use_fallback))

  end

  def error_message(has_translations_with_key, use_fallback)
    if !has_translations_with_key
      # no translations for requested translation_key
      { error: :TRANSLATION_KEY_MISSING }
    elsif !use_fallback
      # no translation for requested locale
      { error: :TRANSLATION_LOCALE_MISSING }
    else
      # translation has a different locale as a fallback option
      { warn: :TRANSLATION_LOCALE_MISSING }
    end
  end

  def from_model_array(models)
    models
      .map { |model|
        from_model(model)
      }
  end

  def from_model(model)
    Maybe(model)
      .map { |m| EntityUtils.model_to_hash(m) }
      .map { |hash| Translation.call(hash) }
      .or_else(nil)
  end

end
